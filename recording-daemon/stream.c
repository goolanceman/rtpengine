#include "stream.h"
#include <glib.h>
#include <pthread.h>
#include <unistd.h>
#include <limits.h>
#include <fcntl.h>
#include <libavcodec/avcodec.h>
#include "metafile.h"
#include "epoll.h"
#include "log.h"
#include "main.h"
#include "packet.h"
#include "forward.h"
#include "recaux.h"


#define MAXBUFLEN 65535
#ifndef AV_INPUT_BUFFER_PADDING_SIZE
#define AV_INPUT_BUFFER_PADDING_SIZE 0
#endif
#ifndef FF_INPUT_BUFFER_PADDING_SIZE
#define FF_INPUT_BUFFER_PADDING_SIZE 0
#endif
#define ALLOCLEN (MAXBUFLEN + AV_INPUT_BUFFER_PADDING_SIZE + FF_INPUT_BUFFER_PADDING_SIZE)


// stream is locked
void stream_close(stream_t *stream) {
	if (stream->fd == -1)
		return;
	metafile_t *mf = stream->metafile;
	const char *cid = (mf && mf->call_id) ? mf->call_id
		: (mf && mf->name ? mf->name : "(unknown)");
	/* stream lock held */
	int pkts = stream->packets_read;
	int rtp = stream->packets_rtp;
	int rtcp = stream->packets_rtcp;
	int dec_ok = stream->packets_decode_ok;
	int dec_fail = stream->packets_decode_fail;
	int parse_err = stream->packets_parse_err;
	int dupe = stream->packets_dupe;
	gint64 bytes = stream->bytes_read;
	const char *codec = stream->codec_seen[0] ? stream->codec_seen : "(none)";
	if (rtp == 0)
		ilog(LOG_WARN,
			"recording STREAM    call-id=%s%s%s"
			"  status=CLOSED       stream=%s  codec=%s"
			"  packets_read=%d  bytes=%" G_GINT64_FORMAT
			"  rtp=%d  rtcp=%d  decode_ok=%d  decode_fail=%d  parse_err=%d"
			"  | WARN: no RTP packets on this stream",
			FMT_M(cid),
			stream->name ? stream->name : "(unnamed)",
			codec, pkts, bytes, rtp, rtcp, dec_ok, dec_fail, parse_err);
	else
		ilog(LOG_NOTICE,
			"recording STREAM    call-id=%s%s%s"
			"  status=CLOSED       stream=%s  codec=%s"
			"  packets_read=%d  bytes=%" G_GINT64_FORMAT
			"  rtp=%d  rtcp=%d  decode_ok=%d  decode_fail=%d  parse_err=%d  dupe=%d"
			"  | Kernel intercept stream closed",
			FMT_M(cid),
			stream->name ? stream->name : "(unnamed)",
			codec, pkts, bytes, rtp, rtcp, dec_ok, dec_fail, parse_err, dupe);
	if (mf) {
		g_atomic_int_add(&mf->packets_read, pkts);
		g_atomic_int_add(&mf->packets_rtp, rtp);
		g_atomic_int_add(&mf->packets_rtcp, rtcp);
		g_atomic_int_add(&mf->packets_decode_ok, dec_ok);
		g_atomic_int_add(&mf->packets_decode_fail, dec_fail);
		g_atomic_int_add(&mf->packets_parse_err, parse_err);
		g_atomic_int_add(&mf->packets_dupe, dupe);
		/* bytes accumulated under mf lock elsewhere; approximate here */
		mf->bytes_read += bytes;
		if (rtp == 0)
			g_atomic_int_inc(&mf->streams_no_rtp);
	}
	epoll_del(stream->fd);
	close(stream->fd);
	stream->fd = -1;
}

void stream_free(stream_t *stream) {
	g_slice_free1(sizeof(*stream), stream);
}


static void stream_handler(handler_t *handler) {
	stream_t *stream = handler->ptr;
	unsigned char *buf = NULL;

	log_info_call = stream->metafile->name;
	log_info_stream = stream->name;

	//dbg("poll event for %s", stream->name);

	while (true) {
		pthread_mutex_lock(&stream->lock);

		if (stream->fd == -1)
			break;

		buf = malloc(ALLOCLEN);
		int ret = read(stream->fd, buf, MAXBUFLEN);
		if (ret == 0) {
			ilog(LOG_NOTICE,
				"recording STREAM    call-id=%s%s%s"
				"  status=EOF          stream=%s"
				"  | End of stream (no more media from kernel)",
				FMT_M(stream->metafile && stream->metafile->call_id
					? stream->metafile->call_id
					: (stream->metafile && stream->metafile->name ? stream->metafile->name : "(unknown)")),
				stream->name ? stream->name : "(unnamed)");
			stream_close(stream);
			break;
		}
		else if (ret < 0) {
			if (errno == EAGAIN || errno == EINTR || errno == EWOULDBLOCK)
				break;
			ilog(LOG_NOTICE,
				"recording STREAM    call-id=%s%s%s"
				"  status=READ_ERROR   stream=%s  err=%s"
				"  | Stream read error; closing",
				FMT_M(stream->metafile && stream->metafile->call_id
					? stream->metafile->call_id
					: (stream->metafile && stream->metafile->name ? stream->metafile->name : "(unknown)")),
				stream->name ? stream->name : "(unnamed)",
				strerror(errno));
			stream_close(stream);
			break;
		}

		// got a packet
		stream->packets_read++;
		stream->bytes_read += ret;
		pthread_mutex_unlock(&stream->lock);

		if (forward_to){
			if (forward_packet(stream->metafile,buf,ret)) // leaves buf intact
				g_atomic_int_inc(&stream->metafile->forward_failed);
			else
				g_atomic_int_inc(&stream->metafile->forward_count);
		}
		if (decoding_enabled)
			packet_process(stream, buf, ret); // consumes buf
		else
			free(buf);

		buf = NULL;
	}

	pthread_mutex_unlock(&stream->lock);
	if (buf)
		free(buf);
	log_info_call = NULL;
	log_info_stream = NULL;
}


// mf is locked
static stream_t *stream_get(metafile_t *mf, unsigned long id) {
	if (mf->streams->len <= id)
		g_ptr_array_set_size(mf->streams, id + 1);
	stream_t *ret = g_ptr_array_index(mf->streams, id);
	if (ret)
		goto out;

	ret = g_slice_alloc0(sizeof(*ret));
	g_ptr_array_index(mf->streams, id) = ret;
	pthread_mutex_init(&ret->lock, NULL);
	ret->fd = -1;
	ret->id = id;
	ret->metafile = mf;
	ret->tag = (unsigned long) -1;
	ret->start_time = now_double();

out:
	return ret;
}


// mf is locked
void stream_open(metafile_t *mf, unsigned long id, char *name) {
	dbg("opening stream %lu/%s", id, name);

	stream_t *stream = stream_get(mf, id);

	stream->name = g_string_chunk_insert(mf->gsc, name);

	char fnbuf[PATH_MAX];
	snprintf(fnbuf, sizeof(fnbuf), "/proc/rtpengine/%u/calls/%s/%s", ktable, mf->parent, name);

	stream->fd = open(fnbuf, O_RDONLY | O_NONBLOCK);
	if (stream->fd == -1) {
		ilog(LOG_ERR,
			"recording STREAM    call-id=%s%s%s"
			"  status=NOT_OPENED   stream=%s  path=%s  err=%s"
			"  | FAILED to open kernel intercept stream",
			FMT_M(mf->call_id ? mf->call_id : mf->name),
			name, fnbuf, strerror(errno));
		return;
	}

	ilog(LOG_NOTICE,
		"recording STREAM    call-id=%s%s%s"
		"  status=OPENED       stream=%s  path=%s"
		"  | Kernel intercept stream opened for reading",
		FMT_M(mf->call_id ? mf->call_id : mf->name),
		name, fnbuf);
	g_atomic_int_inc(&mf->streams_opened);

	// add to epoll
	stream->handler.ptr = stream;
	stream->handler.func = stream_handler;
	epoll_add(stream->fd, EPOLLIN, &stream->handler);
}

void stream_details(metafile_t *mf, unsigned long id, unsigned int tag, unsigned int media_sdp_id) {
	stream_t *stream = stream_get(mf, id);
	stream->tag = tag;
	stream->media_sdp_id = media_sdp_id;
}

void stream_forwarding_on(metafile_t *mf, unsigned long id, unsigned int on) {
	stream_t *stream = stream_get(mf, id);
	dbg("Setting forwarding flag to %u for stream #%lu", on, stream->id);
	stream->forwarding_on = on ? 1 : 0;
}
