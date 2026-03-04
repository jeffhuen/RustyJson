use num_bigint::BigInt;
use rustler::{Term, TermType};

/// Maximum absolute exponent allowed for Decimal formatting.
/// Matches the decoder's `integer_digit_limit` default of 1024. Exponents beyond
/// this would produce strings exceeding 1024 characters from the exponent alone,
/// which is either malformed data or a DoS attempt. Returns `None` (falling back
/// to generic map encoding) rather than attempting the allocation.
///
/// Note: coefficient size is not capped here — BigInt coefficients with millions
/// of digits could still produce large strings. In practice, Elixir's Decimal
/// library constrains coefficient size more than it constrains exponents.
const MAX_EXP: i32 = 1024;

/// Checks if a term is an Elixir.Decimal struct and returns its string representation if so.
///
/// Decimal structs have the shape: %Decimal{coef: integer, exp: integer, sign: 1 | -1}
/// For example, Decimal.new("123.45") = %Decimal{coef: 12345, exp: -2, sign: 1}
///
/// Uses pre-interned atoms from `crate::atoms` to avoid per-call `Atom::from_str`
/// overhead. Previous implementation called `Atom::from_str` 5 times per encode,
/// hammering the atom table lock under high throughput and causing scheduler
/// contention that manifested as connection timeouts.
pub fn try_format_decimal(term: &Term) -> Option<String> {
    if term.get_type() != TermType::Map {
        return None;
    }

    let env = term.get_env();

    // Verify this is an Elixir.Decimal struct before extracting fields.
    // Uses pre-interned atoms from crate::atoms instead of Atom::from_str per-call
    // to avoid repeated atom table lock acquisitions under high throughput.
    let struct_name = term.map_get(crate::atoms::__struct__().to_term(env)).ok()?;
    if !struct_name.eq(&crate::atoms::decimal_struct().to_term(env)) {
        return None;
    }

    let coef_term = term.map_get(crate::atoms::coef().to_term(env)).ok()?;
    let exp_term = term.map_get(crate::atoms::exp().to_term(env)).ok()?;
    let sign_term = term.map_get(crate::atoms::sign().to_term(env)).ok()?;

    let exp: i32 = exp_term.decode().ok()?;
    let sign: i32 = sign_term.decode().ok()?;

    // Reject absurd exponents that would produce unbounded string allocations.
    // Positive extremes attempt massive trailing/leading zero strings (DoS);
    // negative extremes can overflow usize on cast and panic.
    if !(-MAX_EXP..=MAX_EXP).contains(&exp) {
        return None;
    }

    // Fast path: decode coef as i128 (Rustler short-circuits through i64 for small
    // values). Avoids BigInt's term-to-binary round-trip for common Decimals.
    // Falls back to BigInt only for coefficients exceeding i128::MAX (39 digits).
    if let Ok(coef) = coef_term.decode::<i128>() {
        Some(format_decimal_i128(coef, exp, sign))
    } else {
        let coef: BigInt = coef_term.decode().ok()?;
        Some(format_decimal_str(&coef.to_string(), exp, sign))
    }
}

/// Format a Decimal from an `i128` coefficient.
///
/// For non-negative exponents, formats directly from the integer via `Display`
/// without an intermediate String allocation for the coefficient digits.
/// For negative exponents, falls back to string-based digit splitting.
fn format_decimal_i128(coef: i128, exp: i32, sign: i32) -> String {
    let sign_str = if sign < 0 { "-" } else { "" };

    if exp >= 0 {
        // Format i128 directly — no intermediate coef_str allocation
        let zeros = "0".repeat(exp as usize);
        format!("{sign_str}{coef}{zeros}")
    } else {
        // Need string representation for decimal point insertion
        format_decimal_str(&coef.to_string(), exp, sign)
    }
}

/// Format a Decimal from its coefficient digit string, exponent, and sign.
///
/// `coef_str` is the base-10 digit string of the coefficient (always non-negative).
/// Used for the negative-exponent path of `format_decimal_i128` and as the sole
/// path for BigInt coefficients exceeding `i128::MAX`.
fn format_decimal_str(coef_str: &str, exp: i32, sign: i32) -> String {
    let sign_str = if sign < 0 { "-" } else { "" };

    if exp >= 0 {
        let zeros = "0".repeat(exp as usize);
        format!("{sign_str}{coef_str}{zeros}")
    } else {
        let decimal_places = (-exp) as usize;

        if decimal_places >= coef_str.len() {
            // Need leading zeros after decimal point
            let leading_zeros = decimal_places - coef_str.len();
            format!("{sign_str}0.{}{coef_str}", "0".repeat(leading_zeros))
        } else {
            // Insert decimal point within the number
            let (integer_part, decimal_part) = coef_str.split_at(coef_str.len() - decimal_places);
            format!("{sign_str}{integer_part}.{decimal_part}")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_decimal_i128() {
        assert_eq!(format_decimal_i128(12345, -2, 1), "123.45");
        assert_eq!(format_decimal_i128(12345, -2, -1), "-123.45");
        assert_eq!(format_decimal_i128(5, 0, 1), "5");
        assert_eq!(format_decimal_i128(1, 3, 1), "1000");
        assert_eq!(format_decimal_i128(1, -3, 1), "0.001");
        assert_eq!(format_decimal_i128(123, -5, 1), "0.00123");
    }

    #[test]
    fn test_format_decimal_str_exceeding_i128_max() {
        // Coefficient just above i128::MAX (170141183460469231731687303715884105727).
        // This exercises the BigInt fallback path — previously these silently
        // encoded as a raw map instead of a quoted decimal string.
        let coef = (BigInt::from(i128::MAX) + BigInt::from(1)).to_string();
        assert_eq!(
            format_decimal_str(&coef, 0, 1),
            "170141183460469231731687303715884105728"
        );
        assert_eq!(
            format_decimal_str(&coef, -10, 1),
            "17014118346046923173168730371.5884105728"
        );
        assert_eq!(
            format_decimal_str(&coef, 0, -1),
            "-170141183460469231731687303715884105728"
        );
    }

    #[test]
    fn test_format_decimal_str_positive_exp() {
        // Exercises trailing-zero growth for the BigInt string path
        let coef = (BigInt::from(i128::MAX) + BigInt::from(1)).to_string();
        assert_eq!(
            format_decimal_str(&coef, 5, 1),
            "17014118346046923173168730371588410572800000"
        );
        assert_eq!(
            format_decimal_str(&coef, 5, -1),
            "-17014118346046923173168730371588410572800000"
        );
    }
}
