//! Pure-Rust rule compilation: YAML / `serde_yaml::Value` rule documents to a
//! [`RuleCollection`], independent of Erlang terms so it can be unit tested.

use std::collections::HashSet;

use ast_grep_config::{
    DeserializeEnv, GlobalRules, RuleCollection, RuleConfig, SerializableGlobalRule,
    SerializableRuleConfig,
};
use ast_grep_language::SupportLang;
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_yaml::with::singleton_map_recursive;
use serde_yaml::Value;

/// A rule source: a YAML string (possibly holding several `---` separated
/// documents) or a single already-parsed document.
pub enum Source {
    Yaml(String),
    Value(serde_yaml::Value),
}

/// Compiles rule and global utility rule sources into a [`RuleCollection`].
///
/// Errors are human readable messages naming the offending rule when known.
pub fn compile(
    rules: Vec<Source>,
    utils: Vec<Source>,
) -> Result<RuleCollection<SupportLang>, String> {
    let mut util_configs: Vec<SerializableGlobalRule<SupportLang>> = vec![];
    for util in utils {
        util_configs.extend(documents(util, "utility rule")?);
    }
    let globals = global_rules(util_configs)?;

    let mut configs = vec![];
    let mut ids = HashSet::new();
    for rule in rules {
        let docs: Vec<SerializableRuleConfig<SupportLang>> = documents(rule, "rule")?;
        for doc in docs {
            let id = doc.id.clone();
            // Like the `sg` CLI, reject duplicates (suppression comments and
            // reports refer to rules by id).
            if !ids.insert(id.clone()) {
                return Err(format!("duplicate rule id `{}`", id));
            }
            let config = RuleConfig::try_from(doc, &globals)
                .map_err(|e| format!("invalid rule `{}`: {}", id, error_chain(&e)))?;
            configs.push(config);
        }
    }

    RuleCollection::try_new(configs).map_err(|e| format!("invalid `files`/`ignores` glob: {}", e))
}

/// Builds the global utility rules.
fn global_rules(utils: Vec<SerializableGlobalRule<SupportLang>>) -> Result<GlobalRules, String> {
    if utils.is_empty() {
        return Ok(GlobalRules::default());
    }
    let globals =
        DeserializeEnv::<SupportLang>::parse_global_utils(utils.clone()).map_err(|e| {
            let message = error_chain(&e);
            // The error does not say which utility rule it is about: find the
            // one failing with the same error on its own (errors such as
            // duplicate or cyclic ids, which name the ids, do not reproduce).
            let culprit = utils.iter().find(|util| {
                DeserializeEnv::parse_global_utils(vec![(*util).clone()])
                    .is_err_and(|e| error_chain(&e) == message)
            });
            match culprit {
                Some(util) => format!("invalid utility rule `{}`: {}", util.id, message),
                None => format!("invalid utility rules: {}", message),
            }
        })?;

    // ast-grep resolves the `matches` references of global utility rules
    // lazily: a reference to an undefined utility rule is only reported when
    // a rule using it is compiled (as "Rule must specify a set of AST kinds"
    // at best), and silently never matches otherwise. Recompile each utility
    // rule against the complete set, with the checks used for rules.
    //
    // Parameterized utilities are skipped: their parameters would be seen as
    // undefined ids. (Calls to undefined parameterized utilities are already
    // rejected by `parse_global_utils`.)
    for util in utils
        .iter()
        .filter(|u| u.arguments.as_deref().unwrap_or_default().is_empty())
    {
        let env = DeserializeEnv::new(util.language).with_globals(&globals);
        util.core
            .get_matcher(env)
            .map_err(|e| format!("invalid utility rule `{}`: {}", util.id, error_chain(&e)))?;
    }
    Ok(globals)
}

/// Deserializes all the documents of `source`. Empty YAML documents are
/// skipped.
fn documents<T: DeserializeOwned>(source: Source, what: &str) -> Result<Vec<T>, String> {
    match source {
        Source::Yaml(yaml) => {
            // A first pass finds the empty documents (e.g. after a trailing
            // `---`); the second deserializes the others straight from the
            // YAML so errors keep their line and column.
            let mut docs = vec![];
            let values = serde_yaml::Deserializer::from_str(&yaml).map(Value::deserialize);
            for (de, value) in serde_yaml::Deserializer::from_str(&yaml).zip(values) {
                let value = value.map_err(|e| format!("invalid {} YAML: {}", what, e))?;
                if value.is_null() {
                    continue;
                }
                let doc = singleton_map_recursive::deserialize(de)
                    .map_err(|e| format!("invalid {} YAML: {}", what, e))?;
                docs.push(doc);
            }
            Ok(docs)
        }
        Source::Value(value) => {
            let doc = singleton_map_recursive::deserialize(value)
                .map_err(|e| format!("invalid {}: {}", what, e))?;
            Ok(vec![doc])
        }
    }
}

/// Formats an error and its chain of sources, skipping causes whose message
/// is already included.
pub fn error_chain(err: &dyn std::error::Error) -> String {
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

#[cfg(test)]
mod tests {
    use super::*;
    use ast_grep_config::RuleCollection;
    use ast_grep_language::SupportLang;

    const RULE: &str = "
id: no-io-inspect
language: elixir
severity: warning
message: Remove IO.inspect($A)
rule:
  pattern: IO.inspect($A)
fix: $A
";

    fn yaml(s: &str) -> Source {
        Source::Yaml(s.to_string())
    }

    fn value(s: &str) -> Source {
        Source::Value(serde_yaml::from_str::<Value>(s).unwrap())
    }

    fn ids(collection: &RuleCollection<SupportLang>) -> Vec<String> {
        let mut ids = vec![];
        collection.for_each_rule(|rule| ids.push(rule.id.clone()));
        ids.sort();
        ids
    }

    fn compile_err(rules: Vec<Source>, utils: Vec<Source>) -> String {
        match compile(rules, utils) {
            Ok(collection) => panic!("expected an error, compiled {:?}", ids(&collection)),
            Err(message) => message,
        }
    }

    #[test]
    fn compiles_yaml_and_values() {
        let collection = compile(
            vec![
                yaml(RULE),
                value("{id: a, language: ex, rule: {pattern: a()}}"),
            ],
            vec![],
        )
        .unwrap();
        assert_eq!(ids(&collection), ["a", "no-io-inspect"]);
    }

    #[test]
    fn compiles_multi_document_yaml_and_drops_off_rules() {
        let multi = "
id: b
language: elixir
rule: {pattern: b()}
---
id: off-rule
language: elixir
severity: off
rule: {pattern: c()}
---
";
        assert_eq!(ids(&compile(vec![yaml(multi)], vec![]).unwrap()), ["b"]);
        assert!(ids(&compile(vec![], vec![]).unwrap()).is_empty());
    }

    #[test]
    fn resolves_global_utility_rules() {
        let util = yaml("{id: is-dbg, language: elixir, rule: {pattern: 'dbg($$$)'}}");
        let rule = value("{id: no-dbg, language: elixir, rule: {matches: is-dbg}}");
        assert_eq!(ids(&compile(vec![rule], vec![util]).unwrap()), ["no-dbg"]);

        let rule = value("{id: no-dbg, language: elixir, rule: {matches: is-dbg}}");
        let message = compile_err(vec![rule], vec![]);
        assert!(message.starts_with("invalid rule `no-dbg`: "), "{message}");
        assert!(message.contains("`is-dbg` is not defined"), "{message}");
    }

    #[test]
    fn reports_yaml_and_deserialization_errors() {
        let message = compile_err(vec![yaml("id: x\nrule: [\n")], vec![]);
        assert!(message.starts_with("invalid rule YAML: "), "{message}");

        let message = compile_err(vec![], vec![yaml("id: x\nrule: [\n")]);
        assert!(
            message.starts_with("invalid utility rule YAML: "),
            "{message}"
        );

        let message = compile_err(vec![value("{id: x, rule: {pattern: x}}")], vec![]);
        assert!(message.starts_with("invalid rule: "), "{message}");
        assert!(message.contains("language"), "{message}");

        let message = compile_err(
            vec![value("{id: x, language: cobol, rule: {pattern: x}}")],
            vec![],
        );
        assert!(message.contains("cobol is not supported"), "{message}");
    }

    #[test]
    fn reports_invalid_patterns_with_the_rule_id() {
        let message = compile_err(
            vec![value(
                "{id: bad, language: elixir, rule: {pattern: 'foo(('}}",
            )],
            vec![],
        );
        assert!(message.starts_with("invalid rule `bad`: "), "{message}");
        assert!(message.contains("pattern"), "{message}");
    }

    #[test]
    fn reports_invalid_globs() {
        let message = compile_err(
            vec![value(
                "{id: x, language: elixir, rule: {pattern: x}, files: ['[']}",
            )],
            vec![],
        );
        assert!(
            message.starts_with("invalid `files`/`ignores` glob"),
            "{message}"
        );
    }

    #[test]
    fn rejects_duplicate_rule_ids() {
        let message = compile_err(vec![yaml(RULE), yaml(RULE)], vec![]);
        assert_eq!(message, "duplicate rule id `no-io-inspect`");

        // Within a multi-document source, and for disabled rules too.
        let off = "{id: no-io-inspect, language: elixir, severity: off, rule: {pattern: x}}";
        let message = compile_err(vec![yaml(&format!("{RULE}\n---\n{off}"))], vec![]);
        assert_eq!(message, "duplicate rule id `no-io-inspect`");
    }

    #[test]
    fn rejects_utility_rules_referencing_undefined_utility_rules() {
        let util = value("{id: is-dbg, language: elixir, rule: {matches: missing}}");
        let message = compile_err(vec![], vec![util]);
        assert!(
            message.starts_with("invalid utility rule `is-dbg`: "),
            "{message}"
        );
        assert!(message.contains("`missing` is not defined"), "{message}");

        let util =
            value("{id: deep, language: elixir, rule: {kind: call, not: {has: {matches: gone}}}}");
        let message = compile_err(vec![], vec![util]);
        assert!(message.contains("`gone` is not defined"), "{message}");

        let util = value(
            "{id: c, language: elixir, rule: {pattern: $A}, constraints: {A: {matches: gone}}}",
        );
        let message = compile_err(vec![], vec![util]);
        assert!(message.contains("`gone` is not defined"), "{message}");
    }

    #[test]
    fn accepts_references_to_global_local_and_parameterized_utility_rules() {
        let utils = vec![
            value("{id: a, language: elixir, rule: {any: [{matches: b}, {matches: local}]}, utils: {local: {pattern: local()}}}"),
            value("{id: b, language: elixir, rule: {pattern: b()}}"),
            value("{id: wrapped, language: elixir, arguments: [INNER], rule: {kind: call, has: {matches: INNER, stopBy: end}}}"),
            value("{id: uses-wrapped, language: elixir, rule: {matches: {wrapped: {INNER: {matches: b}}}}}"),
        ];
        let rule = value(
            "{id: r, language: elixir, rule: {any: [{matches: a}, {matches: uses-wrapped}]}}",
        );
        assert_eq!(ids(&compile(vec![rule], utils).unwrap()), ["r"]);
    }

    #[test]
    fn names_the_utility_rule_in_utility_rule_errors() {
        let utils = vec![
            value("{id: good, language: elixir, rule: {pattern: good()}}"),
            value("{id: bad-pattern, language: elixir, rule: {pattern: 'foo(('}}"),
        ];
        let message = compile_err(vec![], utils);
        assert!(
            message.starts_with("invalid utility rule `bad-pattern`: "),
            "{message}"
        );

        // Errors naming utility rules themselves are kept as is.
        let utils = vec![
            value("{id: a, language: elixir, rule: {matches: b}}"),
            value("{id: b, language: elixir, rule: {matches: a}}"),
        ];
        let message = compile_err(vec![], utils);
        assert!(message.starts_with("invalid utility rules: "), "{message}");
        assert!(
            message.contains("Rule `a`") || message.contains("Rule `b`"),
            "{message}"
        );

        let utils = vec![
            value("{id: a, language: elixir, rule: {pattern: a}}"),
            value("{id: a, language: elixir, rule: {pattern: b}}"),
        ];
        let message = compile_err(vec![], utils);
        assert!(message.starts_with("invalid utility rules: "), "{message}");
        assert!(message.contains("`a`"), "{message}");
    }
}
