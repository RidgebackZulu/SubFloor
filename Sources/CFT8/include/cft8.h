// SubFloor's interface to the vendored ft8_lib (see ../VENDORED.md). This header and cft8.c are
// SubFloor code; everything under ft8/, common/ and fft/ is upstream ft8_lib, unmodified.
//
// ft8_lib's own headers include each other by root-relative paths (<ft8/decode.h>), which Swift
// clients of this module cannot resolve, so Swift sees only this small API. Every function is
// reentrant (no shared mutable state): safe to call from several threads at once.

#ifndef CFT8_H
#define CFT8_H

#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

/// Channel symbols in one FT8 transmission.
#define CFT8_TONE_COUNT 79
/// Codeword bits (LDPC (174,91)).
#define CFT8_CODEWORD_BITS 174
/// Longest message text, including the terminating NUL (ft8_lib's FTX_MAX_MESSAGE_LENGTH).
#define CFT8_TEXT_CAPACITY 35

/// A decoded message.
typedef struct
{
    /// The message's 79 channel tones (0...7), re-encoded from the decoded payload.
    uint8_t tones[CFT8_TONE_COUNT];
    /// The unpacked message text, NUL-terminated.
    char text[CFT8_TEXT_CAPACITY];
} cft8_message_t;

/// A sync candidate from ft8_lib's waterfall search.
typedef struct
{
    /// Audio frequency of tone 0, in Hz, at the waterfall's resolution (3.125 Hz).
    float frequency_hz;
    /// Start of symbol 0, in seconds from the first input sample, at the waterfall's resolution (80 ms).
    float start_seconds;
    /// ft8_lib's Costas sync score (higher is stronger).
    int score;
} cft8_candidate_t;

/// ft8_lib's analysis of one slot: its monitor's waterfall and its candidate list.
typedef struct cft8_slot cft8_slot_t;

/// Runs ft8_lib's monitor over up to 15 s of 12 kHz audio (`samples[0]` at the slot boundary), for
/// signals whose eight tones all lie in `f_min_hz ... f_max_hz`, and finds up to `max_candidates`
/// Costas sync candidates scoring at least `min_score`, strongest first. Returns NULL on invalid
/// arguments or allocation failure. Free with `cft8_slot_free`.
cft8_slot_t* cft8_slot_analyse(const float* samples, int num_samples, int sample_rate, float f_min_hz,
                               float f_max_hz, int max_candidates, int min_score);

void cft8_slot_free(cft8_slot_t* slot);

int cft8_slot_candidate_count(const cft8_slot_t* slot);

/// Candidate `index` (0 ..< count), or a zero candidate if out of range.
cft8_candidate_t cft8_slot_candidate(const cft8_slot_t* slot, int index);

/// ft8_lib's own decode of candidate `index`: soft bits from its waterfall, belief-propagation LDPC
/// with `max_iterations`, CRC check and unpacking. Returns 1 and fills `message` on success.
/// Hashed callsigns are not resolved (they read `<...>`).
int cft8_slot_decode(const cft8_slot_t* slot, int index, int max_iterations, cft8_message_t* message);

/// Decodes a codeword from 174 soft bits (log p(1)/p(0), codeword order) with ft8_lib's
/// belief-propagation LDPC decoder, CRC check and unpacker. Returns 1 and fills `message` on success.
int cft8_decode_soft_bits(const float soft_bits[CFT8_CODEWORD_BITS], int max_iterations, cft8_message_t* message);

/// Packs `text` (a standard FT8 message such as "CQ W1AW FN31", a non-standard call message or free
/// text) and encodes it into 79 channel tones (0...7). Returns 1 on success, 0 if `text` cannot be
/// packed.
int cft8_encode(const char* text, uint8_t tones[CFT8_TONE_COUNT]);

#ifdef __cplusplus
}
#endif

#endif // CFT8_H
