// SubFloor's interface to the vendored ft8_lib: the slot analysis and decode steps of ft8_lib's
// demo/decode_ft8.c (monitor → candidates → LDPC → CRC → unpack, with its time and frequency
// oversampling) and the packing of gen_ft8.c, without the demo's file and audio I/O, logging or
// global callsign hash table.

#include "cft8.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "common/monitor.h"
#include "ft8/crc.h"
#include "ft8/decode.h"
#include "ft8/encode.h"
#include "ft8/ldpc.h"
#include "ft8/message.h"

/// Waterfall oversampling of ft8_lib's demo decoder: 80 ms × 3.125 Hz.
enum
{
    kTimeOSR = 2,
    kFreqOSR = 2,
};

struct cft8_slot
{
    monitor_t monitor;
    int sample_rate;
    int num_candidates;
    ftx_candidate_t* candidates;
};

cft8_slot_t* cft8_slot_analyse(const float* samples, int num_samples, int sample_rate, float f_min_hz,
                               float f_max_hz, int max_candidates, int min_score)
{
    if (samples == NULL || num_samples <= 0 || sample_rate <= 0 || max_candidates <= 0)
        return NULL;
    if (!(f_min_hz >= 0) || !(f_max_hz <= sample_rate / 2.0f) || !(f_max_hz - f_min_hz >= 8 / FT8_SYMBOL_PERIOD))
        return NULL;
    cft8_slot_t* slot = calloc(1, sizeof(cft8_slot_t));
    if (slot == NULL)
        return NULL;
    slot->candidates = calloc((size_t)max_candidates, sizeof(ftx_candidate_t));
    if (slot->candidates == NULL)
    {
        free(slot);
        return NULL;
    }
    slot->sample_rate = sample_rate;

    const monitor_config_t config = {
        .f_min = f_min_hz,
        .f_max = f_max_hz,
        .sample_rate = sample_rate,
        .time_osr = kTimeOSR,
        .freq_osr = kFreqOSR,
        .protocol = FTX_PROTOCOL_FT8,
    };
    monitor_init(&slot->monitor, &config);
    // monitor_process reads FFT bin (bin · freq_osr + freq_sub) for every bin below max_bin, and the
    // FFT has nfft/2 + 1 bins: f_max within one tone of Nyquist would read past its end.
    const monitor_t* m = &slot->monitor;
    const int last_fft_bin = (m->max_bin - 1) * kFreqOSR + (kFreqOSR - 1);
    if (m->window == NULL || m->last_frame == NULL || m->fft_work == NULL || m->wf.mag == NULL
        || last_fft_bin > m->nfft / 2 || m->min_bin < 0)
    {
        cft8_slot_free(slot);
        return NULL;
    }
    for (int pos = 0; pos + m->block_size <= num_samples; pos += m->block_size)
        monitor_process(&slot->monitor, samples + pos);
    slot->num_candidates = ftx_find_candidates(&m->wf, max_candidates, slot->candidates, min_score);
    return slot;
}

void cft8_slot_free(cft8_slot_t* slot)
{
    if (slot == NULL)
        return;
    monitor_free(&slot->monitor);
    free(slot->candidates);
    free(slot);
}

int cft8_slot_candidate_count(const cft8_slot_t* slot)
{
    return slot == NULL ? 0 : slot->num_candidates;
}

cft8_candidate_t cft8_slot_candidate(const cft8_slot_t* slot, int index)
{
    cft8_candidate_t out = { 0 };
    if (slot == NULL || index < 0 || index >= slot->num_candidates)
        return out;
    const ftx_candidate_t* cand = &slot->candidates[index];
    const monitor_t* m = &slot->monitor;
    out.frequency_hz = (m->min_bin + cand->freq_offset + (float)cand->freq_sub / kFreqOSR) / FT8_SYMBOL_PERIOD;
    // Waterfall row (block b, sub s) is the FFT of the nfft samples ending at (b · time_osr + s + 1)
    // subblocks, so a symbol centred in that frame starts nfft/2 + block_size/2 samples before its end.
    const int frame_end = (cand->time_offset * kTimeOSR + cand->time_sub + 1) * m->subblock_size;
    out.start_seconds = (frame_end - m->nfft / 2 - m->block_size / 2) / (float)slot->sample_rate;
    out.score = cand->score;
    return out;
}

/// Unpacks a CRC-checked payload into `out`. Returns 1 on success.
static int finish_message(const ftx_message_t* message, cft8_message_t* out)
{
    // The all-zero codeword passes the parity and CRC checks; it is never a real transmission.
    bool all_zero = true;
    for (int i = 0; i < FTX_PAYLOAD_LENGTH_BYTES && all_zero; ++i)
        all_zero = message->payload[i] == 0;
    if (all_zero)
        return 0;
    ftx_message_offsets_t offsets;
    if (ftx_message_decode(message, NULL, out->text, &offsets) != FTX_MESSAGE_RC_OK)
        return 0;
    out->text[CFT8_TEXT_CAPACITY - 1] = '\0';
    ft8_encode(message->payload, out->tones);
    return 1;
}

int cft8_slot_decode(const cft8_slot_t* slot, int index, int max_iterations, cft8_message_t* message)
{
    if (slot == NULL || message == NULL || index < 0 || index >= slot->num_candidates || max_iterations <= 0)
        return 0;
    ftx_message_t decoded;
    ftx_decode_status_t status;
    if (!ftx_decode_candidate(&slot->monitor.wf, &slot->candidates[index], max_iterations, &decoded, &status))
        return 0;
    return finish_message(&decoded, message);
}

int cft8_decode_soft_bits(const float soft_bits[CFT8_CODEWORD_BITS], int max_iterations, cft8_message_t* message)
{
    if (soft_bits == NULL || message == NULL || max_iterations <= 0)
        return 0;
    float codeword[FTX_LDPC_N];
    for (int i = 0; i < FTX_LDPC_N; ++i)
    {
        codeword[i] = soft_bits[i];
        if (!(codeword[i] == codeword[i]))
            return 0; // NaN
    }
    uint8_t plain[FTX_LDPC_N];
    int errors = 0;
    bp_decode(codeword, max_iterations, plain, &errors);
    if (errors > 0)
        return 0;

    // Payload and CRC: the first 91 bits, MSB first (as ft8_lib's ftx_decode_candidate packs them).
    uint8_t a91[FTX_LDPC_K_BYTES] = { 0 };
    for (int i = 0; i < FTX_LDPC_K; ++i)
    {
        if (plain[i])
            a91[i / 8] |= (uint8_t)(0x80u >> (i % 8));
    }
    const uint16_t extracted = ftx_extract_crc(a91);
    a91[9] &= 0xF8;
    a91[10] = 0;
    if (extracted != ftx_compute_crc(a91, 96 - 14))
        return 0;
    ftx_message_t decoded;
    memcpy(decoded.payload, a91, FTX_PAYLOAD_LENGTH_BYTES);
    decoded.hash = extracted;
    return finish_message(&decoded, message);
}

int cft8_encode(const char* text, uint8_t tones[CFT8_TONE_COUNT])
{
    if (text == NULL || tones == NULL || strlen(text) >= CFT8_TEXT_CAPACITY)
        return 0;
    ftx_message_t message;
    if (ftx_message_encode(&message, NULL, text) != FTX_MESSAGE_RC_OK)
        return 0;
    ft8_encode(message.payload, tones);
    return 1;
}
