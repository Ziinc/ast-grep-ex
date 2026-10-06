//! Conversion between Erlang terms and `serde_yaml::Value`, so rules can be
//! written as Elixir maps / keyword lists as well as YAML.

use rustler::types::atom;
use rustler::types::map::MapIterator;
use rustler::{Encoder, Env, Term, TermType};
use serde_yaml::{Mapping, Number, Value};

pub fn decode_value(term: Term) -> Result<Value, String> {
    match term.get_type() {
        TermType::Atom => {
            if term == atom::nil().to_term(term.get_env()) {
                Ok(Value::Null)
            } else if let Ok(b) = term.decode::<bool>() {
                Ok(Value::Bool(b))
            } else {
                let name = term
                    .atom_to_string()
                    .map_err(|_| "invalid atom".to_string())?;
                Ok(Value::String(name))
            }
        }
        TermType::Binary => term
            .decode::<String>()
            .map(Value::String)
            .map_err(|_| "binaries must be valid UTF-8".to_string()),
        TermType::Integer => {
            if let Ok(i) = term.decode::<i64>() {
                Ok(Value::Number(Number::from(i)))
            } else {
                term.decode::<u64>()
                    .map(|u| Value::Number(Number::from(u)))
                    .map_err(|_| "integer out of range".to_string())
            }
        }
        TermType::Float => term
            .decode::<f64>()
            .map(|f| Value::Number(Number::from(f)))
            .map_err(|_| "invalid float".to_string()),
        TermType::List => {
            let items: Vec<Term> = term.decode().map_err(|_| "improper list".to_string())?;
            if !items.is_empty() && items.iter().all(is_keyword_pair) {
                let mut mapping = Mapping::new();
                for item in items {
                    let (key, value): (Term, Term) = item.decode().expect("checked keyword pair");
                    mapping.insert(decode_value(key)?, decode_value(value)?);
                }
                Ok(Value::Mapping(mapping))
            } else {
                items
                    .into_iter()
                    .map(decode_value)
                    .collect::<Result<Vec<_>, _>>()
                    .map(Value::Sequence)
            }
        }
        TermType::Map => {
            let iter = MapIterator::new(term).ok_or_else(|| "invalid map".to_string())?;
            let mut mapping = Mapping::new();
            for (key, value) in iter {
                mapping.insert(decode_value(key)?, decode_value(value)?);
            }
            Ok(Value::Mapping(mapping))
        }
        other => Err(format!("unsupported term type {:?}", other)),
    }
}

fn is_keyword_pair(term: &Term) -> bool {
    match term.decode::<(Term, Term)>() {
        Ok((key, _)) => key.get_type() == TermType::Atom,
        Err(_) => false,
    }
}

pub fn encode_value<'a>(env: Env<'a>, value: &Value) -> Term<'a> {
    match value {
        Value::Null => atom::nil().encode(env),
        Value::Bool(b) => b.encode(env),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                i.encode(env)
            } else if let Some(u) = n.as_u64() {
                u.encode(env)
            } else {
                n.as_f64().unwrap_or(f64::NAN).encode(env)
            }
        }
        Value::String(s) => s.encode(env),
        Value::Sequence(items) => items
            .iter()
            .map(|v| encode_value(env, v))
            .collect::<Vec<_>>()
            .encode(env),
        Value::Mapping(mapping) => {
            let mut map = Term::map_new(env);
            for (k, v) in mapping {
                map = map
                    .map_put(encode_value(env, k), encode_value(env, v))
                    .expect("map_put on a map");
            }
            map
        }
        Value::Tagged(tagged) => encode_value(env, &tagged.value),
    }
}
