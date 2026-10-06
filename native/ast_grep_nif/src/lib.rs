//! NIF bindings exposing ast-grep rule compilation and scanning to Elixir.
//!
//! Rules are compiled once into a [`RuleSet`] resource and can then be used to
//! scan any number of sources, from any number of BEAM processes.

mod term;

use std::collections::HashMap;
use std::path::Path;
use std::str::FromStr;

use ast_grep_config::{
    CombinedScan, DeserializeEnv, GlobalRules, LabelStyle, RuleCollection, RuleConfig,
    SerializableGlobalRule, SerializableRuleConfig, Severity,
};
use ast_grep_core::meta_var::MetaVariable;
use ast_grep_core::tree_sitter::StrDoc;
use ast_grep_core::{Node, NodeMatch};
use ast_grep_language::{LanguageExt, SupportLang};
use rustler::{Atom, Encoder, Env, NifStruct, ResourceArc, Term};
use serde::de::DeserializeOwned;
use serde_yaml::with::singleton_map_recursive;

mod atoms {
    rustler::atoms! {
        off,
        hint,
        info,
        warning,
        error,
        primary,
        secondary,
    }
}

type Doc = StrDoc<SupportLang>;

/// A compiled collection of ast-grep rules.
pub struct RuleSet {
    collection: RuleCollection<SupportLang>,
}

#[rustler::resource_impl]
impl rustler::Resource for RuleSet {}

#[derive(NifStruct)]
#[module = "AstGrep.Position"]
struct Position {
    /// 1-based line number.
    line: usize,
    /// 1-based column, counted in characters.
    column: usize,
    /// 0-based byte offset into the source.
    offset: usize,
}

#[derive(NifStruct)]
#[module = "AstGrep.Range"]
struct Range {
    start: Position,
    end: Position,
}

#[derive(NifStruct)]
#[module = "AstGrep.Fix"]
struct Fix {
    title: Option<String>,
    replacement: String,
    /// The byte range of the original source replaced by `replacement`.
    range: Range,
}

#[derive(NifStruct)]
#[module = "AstGrep.Label"]
struct Label {
    style: Atom,
    message: Option<String>,
    range: Range,
}

#[derive(NifStruct)]
#[module = "AstGrep.Match"]
struct Match<'a> {
    rule_id: String,
    language: String,
    severity: Atom,
    message: String,
    note: Option<String>,
    url: Option<String>,
    text: String,
    kind: String,
    range: Range,
    meta_variables: HashMap<String, Term<'a>>,
    labels: Vec<Label>,
    fix: Option<Fix>,
}

#[derive(NifStruct)]
#[module = "AstGrep.Rule"]
struct RuleInfo<'a> {
    id: String,
    language: String,
    severity: Atom,
    message: String,
    note: Option<String>,
    url: Option<String>,
    fixable: bool,
    files: Term<'a>,
    ignores: Term<'a>,
    metadata: Term<'a>,
}

// ---------------------------------------------------------------------------
// NIFs
// ---------------------------------------------------------------------------

#[rustler::nif]
fn languages() -> Vec<String> {
    SupportLang::all_langs()
        .iter()
        .map(|lang| lang.to_string().to_lowercase())
        .collect()
}

#[rustler::nif]
fn normalize_language(lang: String) -> Result<String, String> {
    parse_lang(&lang).map(|l| l.to_string().to_lowercase())
}

#[rustler::nif]
fn language_for_path(path: String) -> Option<String> {
    lang_from_path(&path).map(|l| l.to_string().to_lowercase())
}

/// Compiles rule documents into a [`RuleSet`].
///
/// Both `rules` and `utils` are lists whose elements are either a YAML binary
/// (which may hold several `---` separated documents) or an Elixir map /
/// keyword list describing a single document.
#[rustler::nif(schedule = "DirtyCpu")]
fn compile_rules<'a>(rules: Vec<Term<'a>>, utils: Vec<Term<'a>>) -> Result<ResourceArc<RuleSet>, String> {
    let mut util_configs: Vec<SerializableGlobalRule<SupportLang>> = vec![];
    for util in utils {
        util_configs.extend(documents(util, "utility rule")?);
    }
    let globals = if util_configs.is_empty() {
        GlobalRules::default()
    } else {
        DeserializeEnv::<SupportLang>::parse_global_utils(util_configs)
            .map_err(|e| format!("invalid utility rules: {}", error_chain(&e)))?
    };

    let mut configs = vec![];
    for rule in rules {
        let docs: Vec<SerializableRuleConfig<SupportLang>> = documents(rule, "rule")?;
        for doc in docs {
            let id = doc.id.clone();
            let config = RuleConfig::try_from(doc, &globals)
                .map_err(|e| format!("invalid rule `{}`: {}", id, error_chain(&e)))?;
            configs.push(config);
        }
    }

    let collection = RuleCollection::try_new(configs)
        .map_err(|e| format!("invalid `files`/`ignores` glob: {}", e))?;
    Ok(ResourceArc::new(RuleSet { collection }))
}

#[rustler::nif]
fn rules<'a>(env: Env<'a>, rule_set: ResourceArc<RuleSet>) -> Vec<RuleInfo<'a>> {
    let mut infos = vec![];
    rule_set.collection.for_each_rule(|rule| {
        let to_term = |value: Result<serde_yaml::Value, serde_yaml::Error>| {
            term::encode_value(env, &value.unwrap_or(serde_yaml::Value::Null))
        };
        infos.push(RuleInfo {
            id: rule.id.clone(),
            language: rule.language.to_string().to_lowercase(),
            severity: severity_atom(&rule.severity),
            message: rule.message.clone(),
            note: rule.note.clone(),
            url: rule.url.clone(),
            fixable: !rule.fixer.is_empty(),
            files: to_term(serde_yaml::to_value(&rule.files)),
            ignores: to_term(serde_yaml::to_value(&rule.ignores)),
            metadata: to_term(serde_yaml::to_value(&rule.metadata)),
        });
    });
    infos.sort_by(|a, b| a.id.cmp(&b.id));
    infos
}

/// Scans `source` with every applicable rule in `rule_set`.
///
/// Rules are selected by language and, when `path` is given, by the rules'
/// `files`/`ignores` globs. `ast-grep-ignore` suppression comments are honored.
#[rustler::nif(schedule = "DirtyCpu")]
fn scan<'a>(
    env: Env<'a>,
    rule_set: ResourceArc<RuleSet>,
    source: String,
    lang: Option<String>,
    path: Option<String>,
) -> Result<Vec<Match<'a>>, String> {
    let lang = resolve_lang(lang.as_deref(), path.as_deref())?;
    let path = Path::new(path.as_deref().unwrap_or(""));
    let rules = rule_set.collection.get_rule_from_lang(path, lang);
    if rules.is_empty() {
        return Ok(vec![]);
    }
    let root = lang.ast_grep(&source);
    let combined = CombinedScan::new(rules);
    let result = combined.scan(&root, false);

    let mut matches: Vec<Match<'a>> = result
        .matches
        .into_iter()
        .flat_map(|(rule, nms)| nms.into_iter().map(move |nm| (rule, nm)))
        .map(|(rule, nm)| build_match(env, &source, rule, &nm))
        .collect();
    sort_matches(&mut matches);
    Ok(matches)
}

/// Finds every node matched by any rule in `rule_set`, ignoring suppression
/// comments and severity.
#[rustler::nif(schedule = "DirtyCpu")]
fn find_all<'a>(
    env: Env<'a>,
    rule_set: ResourceArc<RuleSet>,
    source: String,
    lang: Option<String>,
    path: Option<String>,
) -> Result<Vec<Match<'a>>, String> {
    let lang = resolve_lang(lang.as_deref(), path.as_deref())?;
    let root = lang.ast_grep(&source);
    let mut matches = vec![];
    rule_set.collection.for_each_rule(|rule| {
        if rule.language != lang {
            return;
        }
        for nm in root.root().find_all(&rule.matcher) {
            matches.push(build_match(env, &source, rule, &nm));
        }
    });
    sort_matches(&mut matches);
    Ok(matches)
}

/// Parses a (possibly multi-document) YAML string into a list of terms.
/// Mappings become maps with string keys.
#[rustler::nif(schedule = "DirtyCpu")]
fn parse_yaml<'a>(env: Env<'a>, yaml: String) -> Result<Vec<Term<'a>>, String> {
    use serde::Deserialize;
    let mut docs = vec![];
    for de in serde_yaml::Deserializer::from_str(&yaml) {
        let value = serde_yaml::Value::deserialize(de).map_err(|e| e.to_string())?;
        docs.push(term::encode_value(env, &value));
    }
    Ok(docs)
}

/// Returns the tree-sitter syntax tree of `source` as an S-expression-like
/// string, which helps when writing rules (`kind`, `field`, ...).
#[rustler::nif(schedule = "DirtyCpu")]
fn dump_tree(source: String, lang: String) -> Result<String, String> {
    let lang = parse_lang(&lang)?;
    let root = lang.ast_grep(&source);
    let mut out = String::new();
    dump_node(&root.root(), 0, None, &mut out);
    Ok(out)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn parse_lang(lang: &str) -> Result<SupportLang, String> {
    SupportLang::from_str(lang).map_err(|e| e.to_string())
}

fn lang_from_path(path: &str) -> Option<SupportLang> {
    use ast_grep_core::Language;
    SupportLang::from_path(path)
}

fn resolve_lang(lang: Option<&str>, path: Option<&str>) -> Result<SupportLang, String> {
    match (lang, path) {
        (Some(lang), _) => parse_lang(lang),
        (None, Some(path)) => {
            lang_from_path(path).ok_or_else(|| format!("cannot infer language from path `{}`", path))
        }
        (None, None) => Err("either a language or a path is required".to_string()),
    }
}

/// Deserializes all documents held by `term`.
fn documents<T: DeserializeOwned>(term: Term, what: &str) -> Result<Vec<T>, String> {
    if let Ok(yaml) = term.decode::<String>() {
        let mut docs = vec![];
        for de in serde_yaml::Deserializer::from_str(&yaml) {
            let doc = singleton_map_recursive::deserialize(de)
                .map_err(|e| format!("invalid {} YAML: {}", what, e))?;
            docs.push(doc);
        }
        Ok(docs)
    } else {
        let value = term::decode_value(term).map_err(|e| format!("invalid {}: {}", what, e))?;
        let doc = singleton_map_recursive::deserialize(value)
            .map_err(|e| format!("invalid {}: {}", what, e))?;
        Ok(vec![doc])
    }
}

fn error_chain(err: &dyn std::error::Error) -> String {
    let mut msg = err.to_string();
    let mut source = err.source();
    while let Some(cause) = source {
        let cause_msg = cause.to_string();
        if !msg.contains(&cause_msg) {
            msg.push_str(": ");
            msg.push_str(&cause_msg);
        }
        source = cause.source();
    }
    msg
}

fn severity_atom(severity: &Severity) -> Atom {
    match severity {
        Severity::Off => atoms::off(),
        Severity::Hint => atoms::hint(),
        Severity::Info => atoms::info(),
        Severity::Warning => atoms::warning(),
        Severity::Error => atoms::error(),
    }
}

fn sort_matches(matches: &mut [Match]) {
    matches.sort_by(|a, b| {
        (a.range.start.offset, a.range.end.offset, &a.rule_id).cmp(&(
            b.range.start.offset,
            b.range.end.offset,
            &b.rule_id,
        ))
    });
}

fn position(node: &Node<Doc>, pos: ast_grep_core::Position, offset: usize) -> Position {
    Position {
        line: pos.line() + 1,
        column: pos.column(node) + 1,
        offset,
    }
}

fn node_range(start: &Node<Doc>, end: &Node<Doc>) -> Range {
    Range {
        start: position(start, start.start_pos(), start.range().start),
        end: position(end, end.end_pos(), end.range().end),
    }
}

fn offset_range(source: &str, start: usize, end: usize) -> Range {
    Range {
        start: offset_position(source, start),
        end: offset_position(source, end),
    }
}

fn offset_position(source: &str, offset: usize) -> Position {
    let before = &source.as_bytes()[..offset.min(source.len())];
    let line_start = before.iter().rposition(|&b| b == b'\n').map_or(0, |i| i + 1);
    let line = before.iter().filter(|&&b| b == b'\n').count();
    let column = String::from_utf8_lossy(&before[line_start..]).chars().count();
    Position {
        line: line + 1,
        column: column + 1,
        offset,
    }
}

fn build_match<'a>(
    env: Env<'a>,
    source: &str,
    rule: &RuleConfig<SupportLang>,
    nm: &NodeMatch<Doc>,
) -> Match<'a> {
    let node = nm.get_node();
    let meta_env = nm.get_env();

    let mut meta_variables = HashMap::new();
    for var in meta_env.get_matched_variables() {
        match &var {
            MetaVariable::Capture(name, _) => {
                if let Some(bytes) = meta_env.get_var_bytes(&var) {
                    let text = String::from_utf8_lossy(bytes).into_owned();
                    meta_variables.insert(name.clone(), text.encode(env));
                }
            }
            MetaVariable::MultiCapture(name) => {
                let texts: Vec<String> = meta_env
                    .get_multiple_matches(name)
                    .iter()
                    .filter(|n| n.is_named())
                    .map(|n| n.text().into_owned())
                    .collect();
                meta_variables.insert(name.clone(), texts.encode(env));
            }
            _ => {}
        }
    }

    let labels = rule
        .get_labels(nm)
        .into_iter()
        .map(|label| Label {
            style: match label.style {
                LabelStyle::Primary => atoms::primary(),
                LabelStyle::Secondary => atoms::secondary(),
            },
            message: label.message.map(str::to_string),
            range: node_range(&label.start_node, &label.end_node),
        })
        .collect();

    let fix = rule.fixer.first().map(|fixer| {
        let edit = nm.make_edit(&rule.matcher, fixer);
        let end = edit.position + edit.deleted_length;
        Fix {
            title: fixer.title().map(str::to_string),
            replacement: String::from_utf8_lossy(&edit.inserted_text).into_owned(),
            range: offset_range(source, edit.position, end),
        }
    });

    Match {
        rule_id: rule.id.clone(),
        language: rule.language.to_string().to_lowercase(),
        severity: severity_atom(&rule.severity),
        message: rule.get_message(nm),
        note: rule.note.clone(),
        url: rule.url.clone(),
        text: node.text().into_owned(),
        kind: node.kind().into_owned(),
        range: node_range(node, node),
        meta_variables,
        labels,
        fix,
    }
}

fn dump_node(node: &Node<Doc>, depth: usize, field: Option<&str>, out: &mut String) {
    if !node.is_named() {
        return;
    }
    let start = node.start_pos();
    let end = node.end_pos();
    out.push_str(&"  ".repeat(depth));
    if let Some(field) = field {
        out.push_str(field);
        out.push_str(": ");
    }
    out.push_str(&format!(
        "{} ({},{})-({},{})",
        node.kind(),
        start.line() + 1,
        start.column(node) + 1,
        end.line() + 1,
        end.column(node) + 1
    ));
    if node.is_named_leaf() {
        out.push_str(&format!(" {:?}", node.text()));
    }
    out.push('\n');
    let inner = node.get_inner_node();
    for (i, child) in node.children().enumerate() {
        let field = inner.field_name_for_child(i as u32);
        dump_node(&child, depth + 1, field, out);
    }
}

rustler::init!("Elixir.AstGrep.Native");
