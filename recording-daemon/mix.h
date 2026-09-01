#ifndef _MIX_H_
#define _MIX_H_

#include "types.h"
#include <libavutil/frame.h>

#define MIX_MAX_INPUTS 4
/* SIPREC two-party default: stereo L/R. Override with --mix-num-inputs. */
#define MIX_DEFAULT_INPUTS 2

mix_t *mix_new(void);
void mix_destroy(mix_t *mix);
int mix_config(mix_t *, const format_t *format);
int mix_add(mix_t *mix, AVFrame *frame, unsigned int idx, void *, output_t *output);
/* 12.5-style: sticky by SSRC then by stream so hold/SSRC change does not burn channels */
unsigned int mix_get_index(mix_t *, void *ssrc, stream_t *stream);
#endif
