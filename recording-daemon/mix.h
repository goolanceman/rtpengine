#ifndef _MIX_H_
#define _MIX_H_

#include "types.h"
#include <libavutil/frame.h>

#define MIX_MAX_INPUTS 4
/* SIPREC two-party default: stereo L/R (A=ch0, B=ch1). Override with --mix-num-inputs. */
#define MIX_DEFAULT_INPUTS 2

mix_t *mix_new(void);
void mix_destroy(mix_t *mix);
int mix_config(mix_t *, const format_t *format);
int mix_add(mix_t *mix, AVFrame *frame, unsigned int idx, void *, output_t *output);
/*
 * Channel assignment (12.5 SIPREC behaviour):
 *  1) same SSRC keeps slot
 *  2) same stream keeps slot across SSRC change (hold/re-INVITE)
 *  3) same TAG (party/monologue) keeps slot so all A streams share ch0, all B share ch1
 */
unsigned int mix_get_index(mix_t *, void *ssrc, stream_t *stream);
#endif
