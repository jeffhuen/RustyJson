#!/bin/bash
# Generate synthetic seed corpus for fuzz testing
# Targets SIMD chunk boundaries (8, 16, 32 bytes)
set -e

CORPUS="$(dirname "$0")/corpus/seed"
mkdir -p "$CORPUS"

# Helper: write raw bytes to a file
write_seed() {
    local name="$1"
    shift
    printf '%s' "$@" > "$CORPUS/$name"
}

write_seed_raw() {
    local name="$1"
    shift
    printf "$@" > "$CORPUS/$name"
}

# === String seeds (for scan_string and encode_escape) ===

# Empty and minimal strings
write_seed "str_empty" '""'
write_seed "str_one" '"a"'
write_seed "str_space" '" "'

# Strings at SIMD boundary lengths (content length, not including quotes)
# NEON/SSE2 = 16 bytes, AVX2 = 32 bytes
for len in 7 8 9 15 16 17 31 32 33 63 64 65 127 128 129 255 256 257; do
    # All 'a' characters
    content=$(printf 'a%.0s' $(seq 1 $len))
    write_seed "str_plain_${len}" "\"${content}\""
done

# Escape at chunk boundary positions
for pos in 14 15 16 17 30 31 32 33; do
    prefix=$(printf 'a%.0s' $(seq 1 $pos))
    write_seed "str_escape_quote_at_${pos}" "\"${prefix}\\\"rest\""
    write_seed "str_escape_bs_at_${pos}" "\"${prefix}\\\\rest\""
    write_seed "str_escape_n_at_${pos}" "\"${prefix}\\nrest\""
done

# Control characters at boundary positions
for pos in 14 15 16 17 30 31 32 33; do
    prefix=$(printf 'a%.0s' $(seq 1 $pos))
    # \x01 control char
    write_seed_raw "str_ctrl_at_${pos}" "\"${prefix}\x01rest\""
done

# Unicode escapes at boundaries
for pos in 11 12 13 14 15 16 27 28 29 30 31 32; do
    prefix=$(printf 'a%.0s' $(seq 1 $pos))
    write_seed "str_unicode_at_${pos}" "\"${prefix}\\u0041rest\""
done

# Surrogate pairs spanning boundaries
for pos in 9 10 11 12 13 14 15 16 25 26 27 28 29 30 31 32; do
    prefix=$(printf 'a%.0s' $(seq 1 $pos))
    write_seed "str_surrogate_at_${pos}" "\"${prefix}\\uD834\\uDD1Erest\""
done

# Strings with all escape types
write_seed "str_all_escapes" '"quote:\" backslash:\\ slash:\/ newline:\n return:\r tab:\t backspace:\b formfeed:\f"'

# Long string with escapes spread throughout
long_content=""
for i in $(seq 1 20); do
    long_content="${long_content}$(printf 'a%.0s' $(seq 1 15))\\n"
done
write_seed "str_escapes_periodic" "\"${long_content}\""

# === Whitespace seeds ===
write_seed "ws_empty" ""
write_seed "ws_spaces_15" "               x"
write_seed "ws_spaces_16" "                x"
write_seed "ws_spaces_17" "                 x"
write_seed "ws_spaces_31" "                               x"
write_seed "ws_spaces_32" "                                x"
write_seed "ws_spaces_33" "                                 x"
write_seed "ws_mixed" "$(printf ' \t\n\r%.0s' $(seq 1 10))x"
write_seed "ws_only" "$(printf ' %.0s' $(seq 1 100))"

# === Number seeds ===
write_seed "num_zero" "0"
write_seed "num_one" "1"
write_seed "num_neg" "-1"
write_seed "num_large" "12345678901234567890"
write_seed "num_float" "3.14159"
write_seed "num_exp" "1e10"
write_seed "num_neg_exp" "1e-10"
write_seed "num_complex" "-123.456e+789"
write_seed "num_tiny_frac" "0.0000001"
write_seed "num_leading_zero" "01"

# === Structural index seeds ===
write_seed "struct_empty_obj" "{}"
write_seed "struct_empty_arr" "[]"
write_seed "struct_nested" '{"a":{"b":{"c":[1,2,3]}}}'
write_seed "struct_array_16" '[1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6]'
write_seed "struct_deep" "$(python3 -c "print('[' * 64 + '1' + ']' * 64)" 2>/dev/null || echo '[[[[[[[[1]]]]]]]]')"

# Large structural with many commas at boundary
arr_elems=""
for i in $(seq 1 100); do
    if [ -n "$arr_elems" ]; then arr_elems="${arr_elems},"; fi
    arr_elems="${arr_elems}${i}"
done
write_seed "struct_many_elems" "[${arr_elems}]"

# Object with string values containing special chars
write_seed "struct_mixed" '{"key1":"value1","key2":42,"key3":true,"key4":null,"key5":[1,2],"key6":{"nested":"obj"}}'

# === Escaped string seeds ===
write_seed "esc_basic" '\"hello\"'
write_seed "esc_unicode" '\u0048\u0065\u006C\u006C\u006F'
write_seed "esc_surrogate_pair" '\uD834\uDD1E'
write_seed "esc_all_types" '\\\" \\\\ \\/ \\b \\f \\n \\r \\t \\u0041'
write_seed "esc_lone_high" '\uD800'
write_seed "esc_lone_low" '\uDC00'
write_seed "esc_invalid" '\x'

# === Encode escape seeds (UTF-8 strings) ===
write_seed "enc_ascii" "hello world"
write_seed "enc_html" "<script>alert('xss')</script>"
write_seed "enc_unicode" "héllo wörld 你好世界"
write_seed_raw "enc_line_sep" "before\xe2\x80\xa8after"
write_seed_raw "enc_para_sep" "before\xe2\x80\xa9after"
write_seed "enc_mixed_escape" "quote:\" backslash:\\ tab:	newline:
"

# === Number boundary seeds (for parse_integer_fast) ===
write_seed "num_18_digits" "999999999999999999"
write_seed "num_neg_18_digits" "-999999999999999999"
write_seed "num_19_digits" "9999999999999999999"
write_seed "num_i64_max" "9223372036854775807"
write_seed "num_i64_min" "-9223372036854775808"
write_seed "num_i64_max_plus1" "9223372036854775808"
write_seed "num_neg_zero" "-0"
write_seed "num_just_minus" "-"

# === Full JSON structure seeds (for validate_json) ===
write_seed "json_array_same_shape" '[{"a":1,"b":"x"},{"a":2,"b":"y"},{"a":3,"b":"z"}]'
write_seed "json_array_mixed_shape" '[{"a":1,"b":2},{"a":1,"c":3},{"x":9}]'
write_seed "json_flat_object" '{"name":"test","age":42,"active":true}'
write_seed "json_nested_object" '{"a":{"b":{"c":[1,2,3]}}}'
write_seed "json_homogeneous_ints" '[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17]'
write_seed "json_homogeneous_strings" '["a","b","c","d","e","f","g","h","i","j"]'
write_seed "json_mixed_array" '[1,"two",true,null,{"five":5},[6]]'
write_seed "json_empty_containers" '{"a":[],"b":{},"c":[[],{}]}'

# Count seeds
echo "Generated $(ls -1 "$CORPUS" | wc -l | tr -d ' ') seed files in $CORPUS"
