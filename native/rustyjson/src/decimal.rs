use rustler::{Term, TermType};

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

    // Decode values - coef can be very large, so use i128 or handle as string
    let coef: i128 = coef_term.decode().ok()?;
    let exp: i32 = exp_term.decode().ok()?;
    let sign: i32 = sign_term.decode().ok()?;

    Some(format_decimal(coef, exp, sign))
}

/// Format a Decimal value as a string.
///
/// Examples:
/// - coef=12345, exp=-2, sign=1 -> "123.45"
/// - coef=5, exp=0, sign=-1 -> "-5"
/// - coef=1, exp=3, sign=1 -> "1000"
fn format_decimal(coef: i128, exp: i32, sign: i32) -> String {
    let sign_str = if sign < 0 { "-" } else { "" };

    if exp >= 0 {
        // No decimal point needed, just add zeros
        let zeros = "0".repeat(exp as usize);
        format!("{}{}{}", sign_str, coef, zeros)
    } else {
        // Need to insert decimal point
        let coef_str = coef.to_string();
        let decimal_places = (-exp) as usize;

        if decimal_places >= coef_str.len() {
            // Need leading zeros after decimal point
            let leading_zeros = decimal_places - coef_str.len();
            format!("{}0.{}{}", sign_str, "0".repeat(leading_zeros), coef_str)
        } else {
            // Insert decimal point within the number
            let (integer_part, decimal_part) = coef_str.split_at(coef_str.len() - decimal_places);
            format!("{}{}.{}", sign_str, integer_part, decimal_part)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_decimal() {
        // 123.45 = coef=12345, exp=-2, sign=1
        assert_eq!(format_decimal(12345, -2, 1), "123.45");

        // -123.45
        assert_eq!(format_decimal(12345, -2, -1), "-123.45");

        // 5 = coef=5, exp=0, sign=1
        assert_eq!(format_decimal(5, 0, 1), "5");

        // 1000 = coef=1, exp=3, sign=1
        assert_eq!(format_decimal(1, 3, 1), "1000");

        // 0.001 = coef=1, exp=-3, sign=1
        assert_eq!(format_decimal(1, -3, 1), "0.001");

        // 0.00123 = coef=123, exp=-5, sign=1
        assert_eq!(format_decimal(123, -5, 1), "0.00123");
    }
}
