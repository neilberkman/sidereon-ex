//! Size-bounded LZC (Unix `compress` / `.Z`) decoder.
//!
//! The decoding algorithm is adapted from `newtua-lzw-z` 0.1.0's
//! `src/decode.rs`, Copyright (c) 2026 Aleksei Trankov, under MIT OR
//! Apache-2.0. This version checks the configured output bound before every
//! output reservation and append; it never first constructs an unbounded
//! decompressed buffer. See `THIRD-PARTY-NOTICES.md`.

const MAGIC: [u8; 2] = [0x1f, 0x9d];
const BLOCK_MODE_FLAG: u8 = 0x80;
const MAXBITS_MASK: u8 = 0x1f;
const INIT_BITS: u32 = 9;
const MAX_MAXBITS: u32 = 16;
const CLEAR: u32 = 256;

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum DecodeError {
    BadMagic,
    BadMaxBits,
    InvalidCode,
    Truncated,
    SizeLimit,
}

/// Decode a complete `.Z` byte stream, stopping before `limit` output bytes
/// would be exceeded.
pub(crate) fn decode_bounded(input: &[u8], limit: usize) -> Result<Vec<u8>, DecodeError> {
    // `compress` encodes empty input as an empty file.
    if input.is_empty() {
        return Ok(Vec::new());
    }
    if input.len() < 2 {
        return Err(DecodeError::Truncated);
    }
    if input[0] != MAGIC[0] || input[1] != MAGIC[1] {
        return Err(DecodeError::BadMagic);
    }
    if input.len() < 3 {
        return Err(DecodeError::Truncated);
    }

    let flags = input[2];
    let block_mode = (flags & BLOCK_MODE_FLAG) != 0;
    let maxbits = (flags & MAXBITS_MASK) as u32;
    if !(INIT_BITS..=MAX_MAXBITS).contains(&maxbits) {
        return Err(DecodeError::BadMaxBits);
    }
    decode_codes(&input[3..], block_mode, maxbits, limit)
}

/// Read `n_bits` bits at absolute bit offset `bitpos` from `data`, LSB-first.
fn read_code(data: &[u8], total_bits: u64, bitpos: u64, n_bits: u32) -> Option<u32> {
    if bitpos + u64::from(n_bits) > total_bits {
        return None;
    }

    let mut code = 0u32;
    let mut i = 0u32;
    while i < n_bits {
        let position = bitpos + u64::from(i);
        let bit = (data[(position >> 3) as usize] >> (position & 7)) & 1;
        code |= u32::from(bit) << i;
        i += 1;
    }
    Some(code)
}

/// Accept only the zero bits used to round the final code up to a byte.
///
/// A complete ncompress stream can leave at most seven unused bits after its
/// final code, and the encoder zero-fills them. More remaining bits means the
/// archive ended partway through another code. Nonzero padding likewise proves
/// that a code was cut short rather than cleanly byte-padded.
fn validate_terminal_padding(data: &[u8], total_bits: u64, bitpos: u64) -> Result<(), DecodeError> {
    let remaining = total_bits
        .checked_sub(bitpos)
        .ok_or(DecodeError::Truncated)?;
    if remaining > 7 {
        return Err(DecodeError::Truncated);
    }

    for position in bitpos..total_bits {
        if ((data[(position >> 3) as usize] >> (position & 7)) & 1) != 0 {
            return Err(DecodeError::Truncated);
        }
    }
    Ok(())
}

/// Advance to the next ncompress code-group boundary at a width transition.
fn align_to_group(bitpos: u64, n_bits: u32, boundary_offset: u64) -> u64 {
    debug_assert!(bitpos > 0, "alignment requires a prior code read");
    let group_bits = u64::from(n_bits) * 8;
    let previous = bitpos - 1;
    let relative = previous - boundary_offset;
    let padding = group_bits - (relative + group_bits) % group_bits;
    previous + padding
}

fn reserve_output(out: &mut Vec<u8>, additional: usize, limit: usize) -> Result<(), DecodeError> {
    let new_len = out
        .len()
        .checked_add(additional)
        .ok_or(DecodeError::SizeLimit)?;
    if new_len > limit {
        return Err(DecodeError::SizeLimit);
    }

    if new_len > out.capacity() {
        // Grow geometrically for normal decoding performance, but choose the
        // target ourselves so requested decoded capacity never exceeds the
        // configured bound. `try_reserve_exact` then avoids Vec applying a
        // second, uncontrolled geometric-growth policy.
        let initial_chunk = limit.min(4 * 1024);
        let target_capacity = new_len
            .max(out.capacity().saturating_mul(2))
            .max(initial_chunk)
            .min(limit);

        out.try_reserve_exact(target_capacity - out.len())
            .map_err(|_| DecodeError::SizeLimit)?;
    }

    Ok(())
}

fn push_output(out: &mut Vec<u8>, byte: u8, limit: usize) -> Result<(), DecodeError> {
    reserve_output(out, 1, limit)?;
    out.push(byte);
    Ok(())
}

fn append_stack(out: &mut Vec<u8>, stack: &mut Vec<u8>, limit: usize) -> Result<(), DecodeError> {
    reserve_output(out, stack.len(), limit)?;
    while let Some(byte) = stack.pop() {
        out.push(byte);
    }
    Ok(())
}

fn decode_codes(
    data: &[u8],
    block_mode: bool,
    maxbits: u32,
    limit: usize,
) -> Result<Vec<u8>, DecodeError> {
    let max_code_count = 1u32 << maxbits;
    let mut prefix = vec![0u32; max_code_count as usize];
    let mut suffix = vec![0u8; max_code_count as usize];
    for (index, value) in suffix.iter_mut().enumerate().take(256) {
        *value = index as u8;
    }

    let first_free = if block_mode { CLEAR + 1 } else { 256 };
    let mut free_entry = first_free;
    let mut code_width = INIT_BITS;
    let mut max_code = (1u32 << code_width) - 1;

    let total_bits = (data.len() as u64) * 8;
    let mut bit_position = 0u64;
    let mut boundary_offset = 0u64;
    let mut out = Vec::new();
    let mut stack = Vec::new();

    // The first code is always a literal.
    let mut old_code = match read_code(data, total_bits, bit_position, code_width) {
        Some(code) => {
            bit_position += u64::from(code_width);
            code
        }
        None if total_bits == 0 => return Ok(out),
        None => return Err(DecodeError::Truncated),
    };
    if old_code >= 256 {
        return Err(DecodeError::InvalidCode);
    }
    let mut final_character = old_code as u8;
    push_output(&mut out, final_character, limit)?;

    while let Some(raw_code) = read_code(data, total_bits, bit_position, code_width) {
        bit_position += u64::from(code_width);
        let mut code = raw_code;

        if block_mode && code == CLEAR {
            let new_position = align_to_group(bit_position, code_width, boundary_offset);
            boundary_offset = new_position;
            bit_position = new_position;
            free_entry = CLEAR + 1;
            code_width = INIT_BITS;
            max_code = (1u32 << code_width) - 1;

            let Some(literal) = read_code(data, total_bits, bit_position, code_width) else {
                return Err(DecodeError::Truncated);
            };
            bit_position += u64::from(code_width);
            if literal >= 256 {
                return Err(DecodeError::InvalidCode);
            }
            old_code = literal;
            final_character = literal as u8;
            push_output(&mut out, final_character, limit)?;
            continue;
        }

        let input_code = code;
        if code > free_entry {
            return Err(DecodeError::InvalidCode);
        }
        if code == free_entry {
            stack.push(final_character);
            code = old_code;
        }

        // Unwind a dictionary entry in reverse, then append it only after its
        // complete output size has passed the bound check.
        while code >= 256 {
            stack.push(suffix[code as usize]);
            code = prefix[code as usize];
        }
        final_character = code as u8;
        stack.push(final_character);
        append_stack(&mut out, &mut stack, limit)?;

        if free_entry < max_code_count {
            prefix[free_entry as usize] = old_code;
            suffix[free_entry as usize] = final_character;
            free_entry += 1;
            if free_entry > max_code && code_width < maxbits {
                let new_position = align_to_group(bit_position, code_width, boundary_offset);
                boundary_offset = new_position;
                bit_position = new_position;
                code_width += 1;
                max_code = if code_width == maxbits {
                    max_code_count
                } else {
                    (1u32 << code_width) - 1
                };
            }
        }

        old_code = input_code;
    }

    validate_terminal_padding(data, total_bits, bit_position)?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn literal_archive(bytes: &[u8]) -> Vec<u8> {
        let mut archive = vec![MAGIC[0], MAGIC[1], MAX_MAXBITS as u8];
        let mut codes = vec![0u8; (bytes.len() * INIT_BITS as usize).div_ceil(8)];

        for (code_index, byte) in bytes.iter().enumerate() {
            for bit_index in 0..INIT_BITS as usize {
                let bit = (usize::from(*byte) >> bit_index) & 1;
                let position = code_index * INIT_BITS as usize + bit_index;
                codes[position / 8] |= (bit as u8) << (position % 8);
            }
        }

        archive.extend(codes);
        archive
    }

    #[test]
    fn exact_output_limit_succeeds() {
        let archive = literal_archive(b"ABC");
        assert_eq!(decode_bounded(&archive, 3), Ok(b"ABC".to_vec()));
    }

    #[test]
    fn output_one_byte_over_limit_stops_with_size_limit() {
        let archive = literal_archive(b"ABC");
        assert_eq!(decode_bounded(&archive, 2), Err(DecodeError::SizeLimit));
    }

    #[test]
    fn zero_limit_accepts_only_empty_output() {
        assert_eq!(decode_bounded(&[], 0), Ok(Vec::new()));
        assert_eq!(
            decode_bounded(&[MAGIC[0], MAGIC[1], MAX_MAXBITS as u8], 0),
            Ok(Vec::new())
        );
        assert_eq!(
            decode_bounded(&literal_archive(b"A"), 0),
            Err(DecodeError::SizeLimit)
        );
    }

    #[test]
    fn malformed_streams_are_not_reported_as_size_limits() {
        assert_eq!(decode_bounded(&[0x1f], 10), Err(DecodeError::Truncated));
        assert_eq!(
            decode_bounded(&[0x00, 0x01, 0x10], 10),
            Err(DecodeError::BadMagic)
        );
        assert_eq!(
            decode_bounded(&[0x1f, 0x9d, 0x08], 10),
            Err(DecodeError::BadMaxBits)
        );
    }

    #[test]
    fn incomplete_codes_and_nonzero_terminal_padding_are_truncated() {
        assert_eq!(
            decode_bounded(&[MAGIC[0], MAGIC[1], MAX_MAXBITS as u8, b'A'], 10),
            Err(DecodeError::Truncated)
        );

        let two_literals = literal_archive(b"AB");
        assert_eq!(
            decode_bounded(&two_literals[..two_literals.len() - 1], 10),
            Err(DecodeError::Truncated)
        );

        let mut nonzero_padding = literal_archive(b"A");
        *nonzero_padding.last_mut().unwrap() |= 0x80;
        assert_eq!(
            decode_bounded(&nonzero_padding, 10),
            Err(DecodeError::Truncated)
        );
    }
}
