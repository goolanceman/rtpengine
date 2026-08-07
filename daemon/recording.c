#include "recording.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <glib.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <time.h>
#include <pcap.h>
#include <inttypes.h>
#include <errno.h>
#include <unistd.h>
#include <assert.h>
#include <stdarg.h>

#include "call.h"
#include "main.h"
#include "kernel.h"
#include "bencode.h"
#include "rtplib.h"
#include "cdr.h"
#include "log.h"
#include "call_interfaces.h"
#include "media_player.h"

#include "xt_RTPENGINE.h"

struct rec_pcap_format {
	int linktype;
	int headerlen;
	void (*header)(unsigned char *, struct packet_stream *);
};



static int check_main_spool_dir(const char *spoolpath);
static char *recording_setup_file(struct recording *recording, const str *);
static char *meta_setup_file(struct recording *recording, const str *);
static int append_meta_chunk(struct recording *recording, const char *buf, unsigned int buflen,
		const char *label_fmt, ...)
	__attribute__((format(printf,4,5)));
static int vappend_meta_chunk(struct recording *recording, const char *buf, unsigned int buflen,
		const char *label_fmt, va_list ap);

// all methods
static int create_spool_dir_all(const char *spoolpath);
static void init_all(call_t *call);
static void sdp_after_all(struct recording *recording, GString *str, struct call_monologue *ml,
		enum call_opmode opmode);
static void dump_packet_all(struct media_packet *mp, const str *s);
static void finish_all(call_t *call, bool discard);

// pcap methods
static int rec_pcap_create_spool_dir(const char *dirpath);
static void rec_pcap_init(call_t *);
static void sdp_after_pcap(struct recording *, GString *str, struct call_monologue *, enum call_opmode opmode);
static void dump_packet_pcap(struct media_packet *mp, const str *s);
static void finish_pcap(call_t *, bool discard);
static void response_pcap(struct recording *, bencode_item_t *);

// proc methods
static void proc_init(call_t *);
static void sdp_before_proc(struct recording *, const str *, struct call_monologue *, enum call_opmode);
static void sdp_after_proc(struct recording *, GString *str, struct call_monologue *, enum call_opmode opmode);
static void meta_chunk_proc(struct recording *, const char *, const str *);
static void update_flags_proc(call_t *call, bool streams);
static void finish_proc(call_t *, bool discard);
static void dump_packet_proc(struct media_packet *mp, const str *s);
static void init_stream_proc(struct packet_stream *);
static void setup_stream_proc(struct packet_stream *);
static void setup_media_proc(struct call_media *);
static void setup_monologue_proc(struct call_monologue *);
static void kernel_info_proc(struct packet_stream *, struct rtpengine_target_info *);

static void rec_pcap_eth_header(unsigned char *, struct packet_stream *);

#define append_meta_chunk_str(r, str, f...) append_meta_chunk(r, (str)->s, (str)->len, f)
#define vappend_meta_chunk_str(r, str, f, ap) vappend_meta_chunk(r, (str)->s, (str)->len, f, ap)
#define append_meta_chunk_s(r, str, f...) append_meta_chunk(r, (str), strlen(str), f)
#define append_meta_chunk_null(r,f...) append_meta_chunk(r, "", 0, f)


const struct recording_method methods[] = {
	{
		.name = "pcap",
		.kernel_support = 0,
		.create_spool_dir = rec_pcap_create_spool_dir,
		.init_struct = rec_pcap_init,
		.sdp_before = NULL,
		.sdp_after = sdp_after_pcap,
		.meta_chunk = NULL,
		.update_flags = NULL,
		.dump_packet = dump_packet_pcap,
		.finish = finish_pcap,
		.init_stream_struct = NULL,
		.setup_stream = NULL,
		.setup_media = NULL,
		.setup_monologue = NULL,
		.stream_kernel_info = NULL,
		.response = response_pcap,
	},
	{
		.name = "proc",
		.kernel_support = 1,
		.create_spool_dir = check_main_spool_dir,
		.init_struct = proc_init,
		.sdp_before = sdp_before_proc,
		.sdp_after = sdp_after_proc,
		.meta_chunk = meta_chunk_proc,
		.update_flags = update_flags_proc,
		.dump_packet = dump_packet_proc,
		.finish = finish_proc,
		.init_stream_struct = init_stream_proc,
		.setup_stream = setup_stream_proc,
		.setup_media = setup_media_proc,
		.setup_monologue = setup_monologue_proc,
		.stream_kernel_info = kernel_info_proc,
		.response = NULL,
	},
	{
		.name = "all",
		.kernel_support = 0,
		.create_spool_dir = create_spool_dir_all,
		.init_struct = init_all,
		.sdp_before = sdp_before_proc,
		.sdp_after = sdp_after_all,
		.meta_chunk = meta_chunk_proc,
		.update_flags = update_flags_proc,
		.dump_packet = dump_packet_all,
		.finish = finish_all,
		.init_stream_struct = init_stream_proc,
		.setup_stream = setup_stream_proc,
		.setup_media = setup_media_proc,
		.setup_monologue = setup_monologue_proc,
		.stream_kernel_info = kernel_info_proc,
		.response = response_pcap,
	},
};

static const struct rec_pcap_format rec_pcap_format_raw = {
	.linktype = DLT_RAW,
	.headerlen = 0,
};
static const struct rec_pcap_format rec_pcap_format_eth = {
	.linktype = DLT_EN10MB,
	.headerlen = 14,
	.header = rec_pcap_eth_header,
};


// Global file reference to the spool directory.
static char *spooldir = NULL;

const struct recording_method *selected_recording_method;
static const struct rec_pcap_format *rec_pcap_format;



/**
 * Free RTP Engine filesystem settings and structure.
 * Check for and free the RTP Engine spool directory.
 */

void recording_fs_free(void) {
	g_clear_pointer(&spooldir, free);
}

/**
 * Initialize RTP Engine filesystem settings and structure.
 * Check for or create the RTP Engine spool directory.
 */
void recording_fs_init(const char *spoolpath, const char *method_str, const char *format_str) {
	int i;

	// Whether or not to fail if the spool directory does not exist.
	if (spoolpath == NULL || spoolpath[0] == '\0')
		return;

	for (i = 0; i < G_N_ELEMENTS(methods); i++) {
		if (!strcmp(methods[i].name, method_str)) {
			selected_recording_method = &methods[i];
			goto found;
		}
	}

	ilog(LOG_ERROR, "Recording method '%s' not supported", method_str);
	return;

found:
	if(!strcmp("raw", format_str))
		rec_pcap_format = &rec_pcap_format_raw;
	else if(!strcmp("eth", format_str))
		rec_pcap_format = &rec_pcap_format_eth;
	else {
		ilog(LOG_ERR, "Invalid value for recording format \"%s\".", format_str);
		exit(-1);
	}

	spooldir = strdup(spoolpath);

	int path_len = strlen(spooldir);
	// Get rid of trailing "/" if it exists. Other code adds that in when needed.
	if (spooldir[path_len-1] == '/') {
		spooldir[path_len-1] = '\0';
	}
	if (!_rm_ret(create_spool_dir, spooldir)) {
		ilog(LOG_ERR, "Error while setting up spool directory \"%s\".", spooldir);
		ilog(LOG_ERR, "Please run `mkdir %s` and start rtpengine again.", spooldir);
		exit(-1);
	}
}

static int check_create_dir(const char *dir, const char *desc, mode_t creat_mode) {
	struct stat info;

	if (stat(dir, &info) != 0) {
		if (!creat_mode) {
			ilog(LOG_WARN, "%s directory \"%s\" does not exist.", desc, dir);
			return FALSE;
		}
		ilog(LOG_INFO, "Creating %s directory \"%s\".", desc, dir);
		// coverity[toctou : FALSE]
		if (mkdir(dir, creat_mode) == 0)
			return TRUE;
		ilog(LOG_ERR, "Failed to create %s directory \"%s\": %s", desc, dir, strerror(errno));
		return FALSE;
	}
	if(!S_ISDIR(info.st_mode)) {
		ilog(LOG_ERR, "%s file exists, but \"%s\" is not a directory.", desc, dir);
		return FALSE;
	}
	return TRUE;
}

static int check_main_spool_dir(const char *spoolpath) {
	return check_create_dir(spoolpath, "spool", 0700);
}

/**
 * Sets up the spool directory for RTP Engine.
 * If the directory does not exist, return FALSE.
 * If the directory exists, but "$spoolpath/metadata" or "$spoolpath/pcaps"
 * exist as non-directory files, return FALSE.
 * Otherwise, return TRUE.
 *
 * Create the "metadata" and "pcaps" directories if they are not there.
 */
static int rec_pcap_create_spool_dir(const char *spoolpath) {
	int spool_good = TRUE;

	if (!check_main_spool_dir(spoolpath))
		return FALSE;

	// Spool directory exists. Make sure it has inner directories.
	int path_len = strlen(spoolpath);
	char meta_path[path_len + 10];
	char rec_path[path_len + 7];
	char tmp_path[path_len + 5];
	snprintf(meta_path, sizeof(meta_path), "%s/metadata", spoolpath);
	snprintf(rec_path, sizeof(rec_path), "%s/pcaps", spoolpath);
	snprintf(tmp_path, sizeof(tmp_path), "%s/tmp", spoolpath);

	if (!check_create_dir(meta_path, "metadata", 0777))
		spool_good = FALSE;
	if (!check_create_dir(rec_path, "pcaps", 0777))
		spool_good = FALSE;
	if (!check_create_dir(tmp_path, "tmp", 0777))
		spool_good = FALSE;

	return spool_good;
}

// lock must be held
static void update_call_field(call_t *call, str *dst_field, const str *src_field, const char *meta_fmt, ...) {
	if (!call)
		return;

	if (src_field && src_field->len && str_cmp_str(src_field, dst_field))
		call_str_cpy(call, dst_field, src_field);

	if (call->recording && dst_field->len) {
		va_list ap;
		va_start(ap, meta_fmt);
		vappend_meta_chunk_str(call->recording, dst_field, meta_fmt, ap);
		va_end(ap);
	}
}

// lock must be held
void update_metadata_call(call_t *call, const sdp_ng_flags *flags) {
	if (flags && flags->skip_recording_db)
		CALL_SET(call, NO_REC_DB);
	if (call->recording) {
		// must come first because METADATA triggers update to DB
		if (CALL_ISSET(call, NO_REC_DB))
			append_meta_chunk_null(call->recording, "SKIP_DATABASE");
	}

	update_call_field(call, &call->metadata, flags ? &flags->metadata : NULL, "METADATA");
	update_call_field(call, &call->recording_file, flags ? &flags->recording_file : NULL, "RECORDING_FILE");
	update_call_field(call, &call->recording_path, flags ? &flags->recording_path : NULL, "RECORDING_PATH");
	update_call_field(call, &call->recording_pattern, flags ? &flags->recording_pattern : NULL,
			"RECORDING_PATTERN");
}

// lock must be held
void update_metadata_monologue_only(struct call_monologue *ml, const sdp_ng_flags *flags) {
	if (!ml)
		return;

	update_call_field(ml->call, &ml->metadata, flags ? &flags->metadata : NULL,
			"METADATA-TAG %u", ml->unique_id);
	update_call_field(ml->call, &ml->label, NULL, "LABEL %u", ml->unique_id);
}

void update_metadata_monologue(struct call_monologue *ml, const sdp_ng_flags *flags) {
	if (!ml)
		return;

	update_metadata_monologue_only(ml, flags);
	update_metadata_call(ml->call, flags);
}

// lock must be held
static void update_flags_proc(call_t *call, bool streams) {
	append_meta_chunk_null(call->recording, "RECORDING %u", CALL_ISSET(call, RECORDING_ON));
	append_meta_chunk_null(call->recording, "FORWARDING %u", CALL_ISSET(call, REC_FORWARDING));
	update_metadata_call(call, NULL);
	if (!streams)
		return;
	for (__auto_type l = call->streams.head; l; l = l->next) {
		struct packet_stream *ps = l->data;
		append_meta_chunk_null(call->recording, "STREAM %u FORWARDING %u",
				ps->unique_id, ML_ISSET(ps->media->monologue, REC_FORWARDING) ? 1 : 0);
	}
}
static void recording_update_flags(call_t *call, bool streams) {
	_rm(update_flags, call, streams);
}

static void rec_setup_monologue(struct call_monologue *ml) {
	recording_setup_monologue(ml);
	if (ml->rec_player) {
		bool ret = media_player_start(ml->rec_player);
		if (!ret)
			ilog(LOG_WARN, "Failed to start media player for recording announcement");
	}
}

// lock must be held
void recording_start_daemon(call_t *call) {
	if (call->recording) {
		// already active
		ilog(LOG_NOTICE,
			"recording SKIP      call-id=" STR_FORMAT_M
			"  reason=already-active  recording_on=%d"
			"  | Recording already running; start ignored",
			STR_FMT_M(&call->callid),
			CALL_ISSET(call, RECORDING_ON) ? 1 : 0);
		recording_update_flags(call, true);
		return;
	}

	if (!spooldir) {
		ilog(LOG_ERR,
			"recording FAIL      call-id=" STR_FORMAT_M
			"  reason=spool-unset"
			"  | CANNOT start recording: spool directory not configured",
			STR_FMT_M(&call->callid));
		return;
	}

	call->recording = g_slice_alloc0(sizeof(struct recording));
	g_autoptr(char) escaped_callid = g_uri_escape_string(call->callid.s, NULL, 0);
	if (!call->recording_meta_prefix.len) {
		const int rand_bytes = 8;
		char rand_str[rand_bytes * 2 + 1];
		rand_hex_str(rand_str, rand_bytes);
		g_autoptr(char) meta_prefix = g_strdup_printf("%s-%s", escaped_callid, rand_str);
		call_str_cpy(call, &call->recording_meta_prefix, &STR_INIT(meta_prefix));
		call_str_cpy(call, &call->recording_random_tag, &STR_CONST_INIT(rand_str));
	}

	_rm(init_struct, call);

	{
		const char *method_s = selected_recording_method ? selected_recording_method->name : "(none)";
		const char *proc_meta_s = (call->recording && call->recording->proc.meta_filepath)
			? call->recording->proc.meta_filepath : "(none)";
		const char *pcap_file_s = (call->recording && call->recording->pcap.recording_path)
			? call->recording->pcap.recording_path : "(none)";
		const char *meta_prefix = call->recording_meta_prefix.len
			? call->recording_meta_prefix.s : "(none)";
		const char *rand_tag = call->recording_random_tag.len
			? call->recording_random_tag.s : "(none)";
		unsigned int proc_idx = (call->recording
				&& call->recording->proc.call_idx != UNINIT_IDX)
			? call->recording->proc.call_idx : 0;
		int proc_ok = (call->recording && call->recording->proc.call_idx != UNINIT_IDX) ? 1 : 0;
		int pcap_ok = (call->recording && call->recording->pcap.recording_pdumper) ? 1 : 0;
		unsigned int ml_n = 0, media_n = 0, stream_n = 0;
		for (__auto_type l = call->monologues.head; l; l = l->next) ml_n++;
		for (__auto_type l = call->medias.head; l; l = l->next) media_n++;
		for (__auto_type l = call->streams.head; l; l = l->next) stream_n++;

		ilog(LOG_NOTICE,
			"recording START     call-id=" STR_FORMAT_M
			"  method=%s  spool=%s  meta_prefix=%s  random_tag=%s"
			"  metadata=%s  recording_file=%s  path=%s  pattern=%s"
			"  kernel_open=%d  kernel_call_idx=%u"
			"  monologues=%u  medias=%u  streams=%u"
			"  recording_on=%d  forwarding_on=%d"
			"  | Recording started"
			" (audio WAV written later by recording-daemon when media arrives)",
			STR_FMT_M(&call->callid),
			method_s,
			spooldir ? spooldir : "(unset)",
			meta_prefix, rand_tag,
			call->metadata.len ? call->metadata.s : "(none)",
			call->recording_file.len ? call->recording_file.s : "(auto)",
			call->recording_path.len ? call->recording_path.s : "(default)",
			call->recording_pattern.len ? call->recording_pattern.s : "(default)",
			kernel.is_open ? 1 : 0, proc_idx,
			ml_n, media_n, stream_n,
			CALL_ISSET(call, RECORDING_ON) ? 1 : 0,
			CALL_ISSET(call, REC_FORWARDING) ? 1 : 0);

		if (proc_ok && proc_meta_s[0] != '(')
			ilog(LOG_NOTICE,
				"recording FILE      call-id=" STR_FORMAT_M
				"  status=CREATED      type=proc-meta  path=%s"
				"  kernel_call_idx=%u  meta_prefix=%s"
				"  | Control metadata file created for recording-daemon",
				STR_FMT_M(&call->callid), proc_meta_s, proc_idx, meta_prefix);
		else if (!strcmp(method_s, "proc") || !strcmp(method_s, "all"))
			ilog(LOG_NOTICE,
				"recording FILE      call-id=" STR_FORMAT_M
				"  status=NOT_CREATED  type=proc-meta  path=%s"
				"  kernel_open=%d  spool=%s"
				"  | Proc metadata NOT created"
				" (is kernel table open? check /proc/rtpengine)",
				STR_FMT_M(&call->callid), proc_meta_s,
				kernel.is_open ? 1 : 0,
				spooldir ? spooldir : "(unset)");

		if (pcap_ok && pcap_file_s[0] != '(')
			ilog(LOG_NOTICE,
				"recording FILE      call-id=" STR_FORMAT_M
				"  status=CREATED      type=pcap  path=%s"
				"  | PCAP capture file opened",
				STR_FMT_M(&call->callid), pcap_file_s);
	}

	// update main call flags (global recording/forwarding on/off) to prevent recording
	// features from being started when the stream info (through setup_stream) is
	// propagated if recording is actually off
	recording_update_flags(call, false);

	// if recording has been turned on after initial call setup, we must walk
	// through all related objects and initialize the recording stuff. if this
	// function is called right at the start of the call, all of the following
	// is essentially a no-op
	for (__auto_type l = call->monologues.head; l; l = l->next) {
		struct call_monologue *ml = l->data;
		rec_setup_monologue(ml);
	}
	for (__auto_type l = call->medias.head; l; l = l->next) {
		struct call_media *m = l->data;
		recording_setup_media(m);
	}
	for (__auto_type l = call->streams.head; l; l = l->next) {
		struct packet_stream *ps = l->data;
		recording_setup_stream(ps);
		__unkernelize(ps, "recording start");
		__reset_sink_handlers(ps);
	}

	recording_update_flags(call, true);
}
// lock must be held
void recording_start(call_t *call) {
	CALL_SET(call, RECORDING_ON);
	recording_start_daemon(call);
}
// lock must be held
void recording_stop_daemon(call_t *call) {
	if (!call->recording)
		return;

	// check if all recording options are disabled
	if (CALL_ISSET(call, RECORDING_ON)) {
		ilog(LOG_NOTICE,
			"recording SKIP      call-id=" STR_FORMAT_M
			"  reason=still-on"
			"  | Stop ignored; recording flag still enabled",
			STR_FMT_M(&call->callid));
		recording_update_flags(call, true);
		return;
	}
	if (CALL_ISSET(call, REC_FORWARDING)) {
		ilog(LOG_NOTICE,
			"recording SKIP      call-id=" STR_FORMAT_M
			"  reason=forwarding-on"
			"  | Stop ignored; rec-forwarding still enabled",
			STR_FMT_M(&call->callid));
		recording_update_flags(call, true);
		return;
	}

	for (__auto_type l = call->monologues.head; l; l = l->next) {
		struct call_monologue *ml = l->data;
		if (ML_ISSET(ml, REC_FORWARDING)) {
			ilog(LOG_NOTICE,
				"recording SKIP      call-id=" STR_FORMAT_M
				"  reason=ml-forwarding-on"
				"  | Stop ignored; monologue forwarding still enabled",
				STR_FMT_M(&call->callid));
			recording_update_flags(call, true);
			return;
		}
	}

	ilog(LOG_NOTICE,
		"recording STOP      call-id=" STR_FORMAT_M
		"  method=%s  metadata=%s  proc_meta=%s  pcap_file=%s"
		"  path=%s  pattern=%s"
		"  | Turning off call recording",
		STR_FMT_M(&call->callid),
		selected_recording_method ? selected_recording_method->name : "(none)",
		call->metadata.len ? call->metadata.s : "(none)",
		call->recording->proc.meta_filepath ? call->recording->proc.meta_filepath : "(none)",
		call->recording->pcap.recording_path ? call->recording->pcap.recording_path : "(none)",
		call->recording_path.len ? call->recording_path.s : "(default)",
		call->recording_pattern.len ? call->recording_pattern.s : "(default)");
	recording_finish(call, false);
}
// lock must be held
void recording_stop(call_t *call) {
	CALL_CLEAR(call, RECORDING_ON);
	recording_stop_daemon(call);
}
// lock must be held
void recording_pause(call_t *call) {
	CALL_CLEAR(call, RECORDING_ON);
	if (!call->recording)
		return;
	ilog(LOG_NOTICE,
		"recording PAUSE     call-id=" STR_FORMAT_M
		"  metadata=%s  proc_meta=%s"
		"  | Recording paused",
		STR_FMT_M(&call->callid),
		call->metadata.len ? call->metadata.s : "(none)",
		call->recording->proc.meta_filepath ? call->recording->proc.meta_filepath : "(none)");
	recording_update_flags(call, true);
}
// lock must be held
void recording_discard(call_t *call) {
	CALL_CLEAR(call, RECORDING_ON);
	if (!call->recording)
		return;
	ilog(LOG_NOTICE,
		"recording DISCARD   call-id=" STR_FORMAT_M
		"  method=%s  metadata=%s  proc_meta=%s  pcap_file=%s"
		"  path=%s  pattern=%s"
		"  | Turning off recording and discarding outputs (files will NOT be kept)",
		STR_FMT_M(&call->callid),
		selected_recording_method ? selected_recording_method->name : "(none)",
		call->metadata.len ? call->metadata.s : "(none)",
		call->recording->proc.meta_filepath ? call->recording->proc.meta_filepath : "(none)",
		call->recording->pcap.recording_path ? call->recording->pcap.recording_path : "(none)",
		call->recording_path.len ? call->recording_path.s : "(default)",
		call->recording_pattern.len ? call->recording_pattern.s : "(default)");
	recording_finish(call, true);
}


/**
 *
 * Controls the setting of recording variables on a `call_t *`.
 * Sets the `record_call` value on the `struct call`, initializing the
 * recording struct if necessary.
 * If we do not yet have a PCAP file associated with the call, create it
 * and write its file URL to the metadata file.
 *
 * Returns a boolean for whether or not the call is being recorded.
 */
void detect_setup_recording(call_t *call, const sdp_ng_flags *flags) {
	if (!flags)
		return;

	const str *recordcall = &flags->record_call_str;
	/* Prefer call->* copies (NUL-terminated). flags->* may point into NG buffer. */
	const char *md = call->metadata.len ? call->metadata.s : "(none)";
	const char *rpath = call->recording_path.len ? call->recording_path.s : "(default)";
	const char *rpat = call->recording_pattern.len ? call->recording_pattern.s : "(default)";

	if (!str_cmp(recordcall, "yes") || !str_cmp(recordcall, "on") || flags->record_call) {
		ilog(LOG_NOTICE,
			"recording DETECT    call-id=" STR_FORMAT_M
			"  action=start  record_call=yes"
			"  metadata=%s  path=%s  pattern=%s"
			"  | NG requested recording start",
			STR_FMT_M(&call->callid), md, rpath, rpat);
		recording_start(call);
	}
	else if (!str_cmp(recordcall, "no") || !str_cmp(recordcall, "off")) {
		ilog(LOG_NOTICE,
			"recording DETECT    call-id=" STR_FORMAT_M
			"  action=stop  record_call=no  metadata=%s"
			"  | NG requested recording stop",
			STR_FMT_M(&call->callid), md);
		recording_stop(call);
	}
	else if (!str_cmp(recordcall, "discard") || flags->discard_recording) {
		ilog(LOG_NOTICE,
			"recording DETECT    call-id=" STR_FORMAT_M
			"  action=discard  record_call=discard  metadata=%s"
			"  | NG requested discard recording",
			STR_FMT_M(&call->callid), md);
		recording_discard(call);
	}
	else if (recordcall->len != 0)
		ilog(LOG_NOTICE,
			"recording DETECT    call-id=" STR_FORMAT_M
			"  action=none  record_call=" STR_FORMAT
			"  | Unknown record_call value (ignored)",
			STR_FMT_M(&call->callid), STR_FMT(recordcall));
}

static void rec_pcap_init(call_t *call) {
	struct recording *recording = call->recording;

	// Wireshark starts at packet index 1, so we start there, too
	recording->pcap.packet_num = 1;
	mutex_init(&recording->pcap.recording_lock);
	meta_setup_file(recording, &call->recording_meta_prefix);

	// set up pcap file
	char *pcap_path = recording_setup_file(recording, &call->recording_meta_prefix);
	if (pcap_path != NULL && recording->pcap.recording_pdumper != NULL
	    && recording->pcap.meta_fp) {
		// Write the location of the PCAP file to the metadata file
		fprintf(recording->pcap.meta_fp, "%s\n\n", pcap_path);
	}
}

static char *file_path_str(const char *id, const char *prefix, const char *suffix) {
	return g_strdup_printf("%s%s%s%s", spooldir, prefix, id, suffix);
}

/**
 * Create a call metadata file in a temporary location.
 * Attaches the filepath and the file pointer to the call struct.
 */
static char *meta_setup_file(struct recording *recording, const str *meta_prefix) {
	if (spooldir == NULL) {
		// No spool directory was created, so we cannot have metadata files.
		return NULL;
	}

	char *meta_filepath = file_path_str(meta_prefix->s, "/tmp/rtpengine-meta-", ".tmp");
	recording->pcap.meta_filepath = meta_filepath;
	FILE *mfp = fopen(meta_filepath, "w");
	// coverity[check_return : FALSE]
	chmod(meta_filepath, S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH);
	if (mfp == NULL) {
		ilog(LOG_ERROR, "Could not open metadata file: %s%s%s", FMT_M(meta_filepath));
		g_clear_pointer(&recording->pcap.meta_filepath, free);
		return NULL;
	}
	recording->pcap.meta_fp = mfp;
	ilog(LOG_DEBUG, "Wrote metadata file to temporary path: %s%s%s", FMT_M(meta_filepath));
	return meta_filepath;
}

/**
 * Write out a block of SDP to the metadata file.
 */
static void sdp_after_pcap(struct recording *recording, GString *s, struct call_monologue *ml,
		enum call_opmode opmode)
{
	FILE *meta_fp = recording->pcap.meta_fp;
	if (!meta_fp)
		return;

	int meta_fd = fileno(meta_fp);
	// File pointers buffer data, whereas direct writing using the file
	// descriptor does not. Make sure to flush any unwritten contents
	// so the file contents appear in order.
	if (ml->label.len) {
		fprintf(meta_fp, "\nLabel: " STR_FORMAT, STR_FMT(&ml->label));
	}
	fprintf(meta_fp, "\nTimestamp started ms: ");
	fprintf(meta_fp, "%.3lf", ml->started.tv_sec*1000.0+ml->started.tv_usec/1000.0);
	fprintf(meta_fp, "\nSDP mode: ");
	fprintf(meta_fp, "%s", get_opmode_text(opmode));
	fprintf(meta_fp, "\nSDP before RTP packet: %" PRIu64 "\n\n", recording->pcap.packet_num);
	fflush(meta_fp);
	if (write(meta_fd, s->str, s->len) <= 0)
		ilog(LOG_WARN, "Error writing SDP body to metadata file: %s", strerror(errno));
}

/**
 * Writes metadata to metafile, closes file, and renames it to finished location.
 */
static void rec_pcap_meta_finish_file(call_t *call) {
	// This should usually be called from a place that has the call->master_lock
	struct recording *recording = call->recording;

	if (recording == NULL || recording->pcap.meta_fp == NULL) {
		ilog(LOG_INFO, "Trying to clean up recording meta file without a file pointer opened.");
		return;
	}

	// Print start timestamp and end timestamp
	// YYYY-MM-DDThh:mm:ss
	time_t start = call->created.tv_sec;
	time_t end = rtpe_now.tv_sec;
	char timebuffer[20];
	struct tm timeinfo;
	struct timeval *terminate;
	terminate = &(((struct call_monologue *)call->monologues.head->data)->terminated);
	fprintf(recording->pcap.meta_fp, "\nTimestamp terminated ms(first monologue): %.3lf", terminate->tv_sec*1000.0 + terminate->tv_usec/1000.0);
	if (localtime_r(&start, &timeinfo) == NULL) {
		ilog(LOG_ERROR, "Cannot get start local time, while cleaning up recording meta file: %s", strerror(errno));
	} else {
		strftime(timebuffer, 20, "%FT%T", &timeinfo);
		fprintf(recording->pcap.meta_fp, "\n\ncall start time: %s\n", timebuffer);
	}
	if (localtime_r(&end, &timeinfo) == NULL) {
		ilog(LOG_ERROR, "Cannot get end local time, while cleaning up recording meta file: %s", strerror(errno));
	} else {
		strftime(timebuffer, 20, "%FT%T", &timeinfo);
		fprintf(recording->pcap.meta_fp, "call end time: %s\n", timebuffer);
	}

	// Print metadata
	if (call->metadata.len)
		fprintf(recording->pcap.meta_fp, "\n\n"STR_FORMAT"\n", STR_FMT(&call->metadata));
	fclose(recording->pcap.meta_fp);
	recording->pcap.meta_fp = NULL;

	// Get the filename (in between its directory and the file extension)
	// and move it to the finished file location.
	// Rename extension to ".txt".
	int fn_len;
	char *meta_filename = strrchr(recording->pcap.meta_filepath, '/');
	char *meta_ext = NULL;
	if (meta_filename == NULL) {
		meta_filename = recording->pcap.meta_filepath;
	}
	else {
		meta_filename = meta_filename + 1;
	}
	// We can always expect a file extension
	meta_ext = strrchr(meta_filename, '.');
	fn_len = meta_ext - meta_filename;
	int prefix_len = strlen(spooldir) + 10; // constant for "/metadata/" suffix
	int ext_len = 4;     // for ".txt"
	char new_metapath[prefix_len + fn_len + ext_len + 1];
	snprintf(new_metapath, prefix_len+fn_len+1, "%s/metadata/%s", spooldir, meta_filename);
	snprintf(new_metapath + prefix_len+fn_len, ext_len+1, ".txt");
	int return_code = rename(recording->pcap.meta_filepath, new_metapath);
	if (return_code != 0) {
		ilog(LOG_ERROR, "Could not move metadata file \"%s\" to \"%s/metadata/\"",
				 recording->pcap.meta_filepath, spooldir);
	} else {
		ilog(LOG_INFO, "Moved metadata file \"%s\" to \"%s/metadata\"",
				 recording->pcap.meta_filepath, spooldir);
	}

	mutex_destroy(&recording->pcap.recording_lock);
	g_clear_pointer(&recording->pcap.meta_filepath, g_free);
}

/**
 * Closes and discards all output files.
 */
static void rec_pcap_meta_discard_file(call_t *call) {
	struct recording *recording = call->recording;

	if (recording == NULL || recording->pcap.meta_fp == NULL)
		return;

	fclose(recording->pcap.meta_fp);
	recording->pcap.meta_fp = NULL;

	unlink(recording->pcap.recording_path);
	unlink(recording->pcap.meta_filepath);
	g_clear_pointer(&recording->pcap.meta_filepath, free);
}

/**
 * Generate a random PCAP filepath to write recorded RTP stream.
 * Returns path to created file.
 */
static char *recording_setup_file(struct recording *recording, const str *meta_prefix) {
	char *recording_path = NULL;

	if (!spooldir)
		return NULL;
	if (recording->pcap.recording_pd || recording->pcap.recording_pdumper)
		return NULL;

	recording_path = file_path_str(meta_prefix->s, "/pcaps/", ".pcap");
	recording->pcap.recording_path = recording_path;

	recording->pcap.recording_pd = pcap_open_dead(rec_pcap_format->linktype, 65535);
	recording->pcap.recording_pdumper = pcap_dump_open(recording->pcap.recording_pd, recording_path);
	if (recording->pcap.recording_pdumper == NULL) {
		pcap_close(recording->pcap.recording_pd);
		recording->pcap.recording_pd = NULL;
		ilog(LOG_ERROR,
				"recording FILE      status=NOT_CREATED  type=pcap  path=%s"
				"  | FAILED to open PCAP capture file",
				recording_path);
	} else {
		ilog(LOG_NOTICE,
				"recording FILE      status=CREATED      type=pcap  path=%s"
				"  | PCAP capture file opened for writing",
				recording_path);
	}

	return recording_path;
}

/**
 * Flushes PCAP file, closes the dumper and descriptors, and frees object memory.
 */
static void rec_pcap_recording_finish_file(struct recording *recording) {
	const char *path = recording->pcap.recording_path ? recording->pcap.recording_path : "(none)";
	uint64_t pkts = recording->pcap.packet_num;
	if (recording->pcap.recording_pdumper != NULL) {
		pcap_dump_flush(recording->pcap.recording_pdumper);
		pcap_dump_close(recording->pcap.recording_pdumper);
		ilog(LOG_NOTICE,
			"recording FILE      status=SAVED         type=pcap  path=%s  packets=%" PRIu64
			"  | PCAP capture file closed and saved",
			path, pkts);
		g_clear_pointer(&recording->pcap.recording_path, free);
	} else {
		ilog(LOG_NOTICE,
			"recording FILE      status=NOT_CREATED  type=pcap  path=%s  packets=%" PRIu64
			"  | PCAP capture had no open dumper (nothing saved)",
			path, pkts);
	}
	if (recording->pcap.recording_pd != NULL) {
		pcap_close(recording->pcap.recording_pd);
	}
}

// "out" must be at least inp->len + MAX_PACKET_HEADER_LEN bytes
static unsigned int fake_ip_header(unsigned char *out, struct media_packet *mp, const str *inp) {
	endpoint_t *src_endpoint, *dst_endpoint;
        if (!rtpe_config.rec_egress) {
                src_endpoint = &mp->fsin;
                dst_endpoint = &mp->sfd->socket.local;
        }
        else {
                src_endpoint = &mp->sfd->socket.local;
                dst_endpoint = &mp->fsin;
        }

	unsigned int hdr_len =
		endpoint_packet_header(out, src_endpoint, dst_endpoint, inp->len);

	assert(hdr_len <= MAX_PACKET_HEADER_LEN);

	// payload
	memcpy(out + hdr_len, inp->s, inp->len);

	return hdr_len + inp->len;
}

static void rec_pcap_eth_header(unsigned char *pkt, struct packet_stream *stream) {
	memset(pkt, 0, 14);
	uint16_t *hdr16 = (void *) pkt;
	hdr16[6] = htons(stream->selected_sfd->socket.local.address.family->ethertype);
}

/**
 * Write out a PCAP packet with payload string.
 * A fair amount extraneous of packet data is spoofed.
 */
static void stream_pcap_dump(struct media_packet *mp, const str *s) {
	pcap_dumper_t *pdumper = mp->call->recording->pcap.recording_pdumper;
	if (!pdumper)
		return;

	unsigned char pkt[s->len + MAX_PACKET_HEADER_LEN + rec_pcap_format->headerlen];
	unsigned int pkt_len = fake_ip_header(pkt + rec_pcap_format->headerlen, mp, s) + rec_pcap_format->headerlen;
	if (rec_pcap_format->header)
		rec_pcap_format->header(pkt, mp->stream);

	// Set up PCAP packet header
	struct pcap_pkthdr header;
	ZERO(header);
	header.ts = rtpe_now;
	header.caplen = pkt_len;
	header.len = pkt_len;

	// Write the packet to the PCAP file
	// Casting quiets compiler warning.
	pcap_dump((unsigned char *)pdumper, &header, pkt);
}

static void dump_packet_pcap(struct media_packet *mp, const str *s) {
	if (ML_ISSET(mp->media->monologue, NO_RECORDING))
		return;
	struct recording *recording = mp->call->recording;
	mutex_lock(&recording->pcap.recording_lock);
	stream_pcap_dump(mp, s);
	recording->pcap.packet_num++;
	mutex_unlock(&recording->pcap.recording_lock);
}

static void finish_pcap(call_t *call, bool discard) {
	rec_pcap_recording_finish_file(call->recording);
	if (!discard)
		rec_pcap_meta_finish_file(call);
	else
		rec_pcap_meta_discard_file(call);
}

static void response_pcap(struct recording *recording, bencode_item_t *output) {
	if (!recording->pcap.recording_path)
		return;

	bencode_item_t *recordings = bencode_dictionary_add_list(output, "recordings");
	bencode_list_add_string(recordings, recording->pcap.recording_path);
}







void recording_finish(call_t *call, bool discard) {
	if (!call || !call->recording)
		return;

	{
		struct recording *rec = call->recording;
		const char *method = selected_recording_method ? selected_recording_method->name : "(none)";
		const char *metadata = call->metadata.len ? call->metadata.s : "(none)";
		const char *rec_path = call->recording_path.len ? call->recording_path.s : "(default)";
		const char *rec_pat = call->recording_pattern.len ? call->recording_pattern.s : "(default)";
		const char *proc_meta = rec->proc.meta_filepath ? rec->proc.meta_filepath : "(none)";
		const char *pcap_path = rec->pcap.recording_path ? rec->pcap.recording_path : "(none)";
		const char *meta_prefix = call->recording_meta_prefix.len ? call->recording_meta_prefix.s : "(none)";
		uint64_t pcap_pkts = rec->pcap.packet_num;
		unsigned int stream_n = 0;
		uint64_t rtp_in = 0, rtp_out = 0;
		for (__auto_type l = call->streams.head; l; l = l->next) {
			struct packet_stream *ps = l->data;
			if (!ps)
				continue;
			stream_n++;
			if (ps->stats_in)
				rtp_in += atomic64_get_na(&ps->stats_in->packets);
			if (ps->stats_out)
				rtp_out += atomic64_get_na(&ps->stats_out->packets);
		}
		const char *result, *file_status, *human;
		if (discard) {
			result = "discarded";
			file_status = "DISCARDED";
			human = "Call finished; recording DISCARDED (file will not be kept)";
		} else if (pcap_pkts <= 1 && rtp_in == 0 && rtp_out == 0) {
			result = "empty";
			file_status = "NOT_CREATED";
			human = "Call finished; NO RTP media seen (audio file likely NOT created)";
		} else {
			result = "success";
			file_status = "CREATED";
			human = "Call finished; media was present (see recording-daemon for final audio file)";
		}
		ilog(LOG_NOTICE,
			"recording FINISH    call-id=" STR_FORMAT_M
			"  outcome=%s  file_status=%s  method=%s"
			"  metadata=%s  path=%s  pattern=%s"
			"  spool=%s  meta_prefix=%s"
			"  proc_meta=%s  pcap_file=%s  kernel_call_idx=%u"
			"  rtp_in=%" PRIu64 "p  rtp_out=%" PRIu64 "p  pcap_packets=%" PRIu64
			"  streams=%u  discard=%d"
			"  | %s",
			STR_FMT_M(&call->callid),
			result, file_status, method,
			metadata, rec_path, rec_pat,
			spooldir ? spooldir : "(unset)", meta_prefix,
			proc_meta, pcap_path,
			(rec->proc.call_idx != UNINIT_IDX) ? rec->proc.call_idx : 0,
			rtp_in, rtp_out, pcap_pkts,
			stream_n, discard ? 1 : 0,
			human);
	}

	__call_unkernelize(call, "recording finished");

	struct recording *recording = call->recording;

	_rm(finish, call, discard);

	g_slice_free1(sizeof(*(recording)), recording);
	call->recording = NULL;
}








static int open_proc_meta_file(struct recording *recording) {
	int fd;
	fd = open(recording->proc.meta_filepath, O_WRONLY | O_APPEND | O_CREAT, 0666);
	if (fd == -1) {
		ilog(LOG_ERR, "Failed to open recording metadata file '%s' for writing: %s",
				recording->proc.meta_filepath, strerror(errno));
		return -1;
	}
	return fd;
}

static int vappend_meta_chunk_iov(struct recording *recording, struct iovec *in_iov, int iovcnt,
		unsigned int str_len, const char *label_fmt, va_list ap)
{
	int fd = open_proc_meta_file(recording);
	if (fd == -1)
		return -1;

	char label[128];
	int lablen = vsnprintf(label, sizeof(label), label_fmt, ap);
	char infix[128];
	int inflen = snprintf(infix, sizeof(infix), "\n%u:\n", str_len);

	// use writev for an atomic write
	struct iovec iov[iovcnt + 3];
	iov[0].iov_base = label;
	iov[0].iov_len = lablen;
	iov[1].iov_base = infix;
	iov[1].iov_len = inflen;
	memcpy(&iov[2], in_iov, iovcnt * sizeof(*iov));
	iov[iovcnt + 2].iov_base = "\n\n";
	iov[iovcnt + 2].iov_len = 2;

	if (writev(fd, iov, iovcnt + 3) != (str_len + lablen + inflen + 2))
		ilog(LOG_WARN, "writev return value incorrect");

	close(fd); // this triggers the inotify

	return 0;
}

static int vappend_meta_chunk(struct recording *recording, const char *buf, unsigned int buflen,
		const char *label_fmt, va_list ap)
{
	struct iovec iov;
	if (!recording->proc.meta_filepath)
		return -1;

	iov.iov_base = (void *) buf;
	iov.iov_len = buflen;

	int ret = vappend_meta_chunk_iov(recording, &iov, 1, buflen, label_fmt, ap);

	return ret;
}

static int append_meta_chunk(struct recording *recording, const char *buf, unsigned int buflen,
		const char *label_fmt, ...)
{
	va_list ap;
	if (!recording->proc.meta_filepath)
		return -1;
	va_start(ap, label_fmt);
	int ret = vappend_meta_chunk(recording, buf, buflen, label_fmt, ap);
	va_end(ap);

	return ret;
}

static void proc_init(call_t *call) {
	struct recording *recording = call->recording;

	recording->proc.call_idx = UNINIT_IDX;
	if (!kernel.is_open) {
		ilog(LOG_WARN,
			"recording FAIL      call-id=" STR_FORMAT_M
			"  reason=kernel-table-not-open  method=proc  spool=%s  meta_prefix=%s"
			"  | CANNOT start proc recording: kernel table not open"
			" (load module; check /proc/rtpengine/<table>/control)",
			STR_FMT_M(&call->callid),
			spooldir ? spooldir : "(unset)",
			call->recording_meta_prefix.len ? call->recording_meta_prefix.s : "(none)");
		return;
	}
	recording->proc.call_idx = kernel_add_call(call->recording_meta_prefix.s);
	if (recording->proc.call_idx == UNINIT_IDX) {
		ilog(LOG_ERR,
			"recording FAIL      call-id=" STR_FORMAT_M
			"  reason=kernel-add-call  err=%s  meta_prefix=%s"
			"  | FAILED to register call with kernel recording interface",
			STR_FMT_M(&call->callid),
			strerror(errno),
			call->recording_meta_prefix.len ? call->recording_meta_prefix.s : "(none)");
		return;
	}

	recording->proc.meta_filepath = file_path_str(call->recording_meta_prefix.s, "/", ".meta");
	unlink(recording->proc.meta_filepath); // start fresh XXX good idea?

	ilog(LOG_NOTICE,
		"recording FILE      call-id=" STR_FORMAT_M
		"  status=CREATED      type=proc-meta  path=%s"
		"  kernel_call_idx=%u  metadata=%s  path_override=%s  pattern=%s"
		"  | Proc metadata ready; recording-daemon will open streams under /proc",
		STR_FMT_M(&call->callid),
		recording->proc.meta_filepath,
		recording->proc.call_idx,
		call->metadata.len ? call->metadata.s : "(none)",
		call->recording_path.len ? call->recording_path.s : "(default)",
		call->recording_pattern.len ? call->recording_pattern.s : "(default)");

	append_meta_chunk_str(recording, &call->callid, "CALL-ID");
	append_meta_chunk_s(recording, call->recording_meta_prefix.s, "PARENT");
	append_meta_chunk_s(recording, call->recording_random_tag.s, "RANDOM_TAG");
}

static void sdp_before_proc(struct recording *recording, const str *sdp, struct call_monologue *ml,
		enum call_opmode opmode)
{
	append_meta_chunk_str(recording, sdp,
			"SDP from %u before %s", ml->unique_id, get_opmode_text(opmode));
}

static void sdp_after_proc(struct recording *recording, GString *s, struct call_monologue *ml,
		enum call_opmode opmode)
{
	append_meta_chunk(recording, s->str, s->len,
			"SDP from %u after %s", ml->unique_id, get_opmode_text(opmode));
}

static void finish_proc(call_t *call, bool discard) {
	struct recording *recording = call->recording;
	if (!kernel.is_open)
		return;
	if (recording->proc.call_idx != UNINIT_IDX) {
		kernel_del_call(recording->proc.call_idx);
		recording->proc.call_idx = UNINIT_IDX;
	}
	for (__auto_type l = call->streams.head; l; l = l->next) {
		struct packet_stream *ps = l->data;
		ps->recording.proc.stream_idx = UNINIT_IDX;
	}

	const char *unlink_fn = recording->proc.meta_filepath;
	g_autoptr(char) discard_fn = NULL;
	if (discard) {
		discard_fn = g_strdup_printf("%s.DISCARD", recording->proc.meta_filepath);
		int ret = rename(recording->proc.meta_filepath, discard_fn);
		if (ret)
			ilog(LOG_ERR, "Failed to rename metadata file \"%s\" to \"%s\": %s",
					recording->proc.meta_filepath,
					discard_fn,
					strerror(errno));
		unlink_fn = discard_fn;
	}

	int ret = unlink(unlink_fn);
	if (ret)
		ilog(LOG_ERR,
			"recording FILE      call-id=" STR_FORMAT_M
			"  status=NOT_REMOVED  type=proc-meta  path=%s  discard=%d  err=%s"
			"  | FAILED to remove proc metadata file",
			STR_FMT_M(&call->callid),
			unlink_fn, discard ? 1 : 0, strerror(errno));
	else
		ilog(LOG_NOTICE,
			"recording FILE      call-id=" STR_FORMAT_M
			"  status=REMOVED      type=proc-meta  path=%s  discard=%d"
			"  | Proc metadata removed; recording-daemon signaled",
			STR_FMT_M(&call->callid),
			unlink_fn, discard ? 1 : 0);

	g_clear_pointer(&recording->proc.meta_filepath, free);
}

static void init_stream_proc(struct packet_stream *stream) {
	stream->recording.proc.stream_idx = UNINIT_IDX;
}

static void setup_stream_proc(struct packet_stream *stream) {
	struct call_media *media = stream->media;
	struct call_monologue *ml = media->monologue;
	call_t *call = stream->call;
	struct recording *recording = call->recording;
	char buf[128];
	int len;

	if (!recording)
		return;
	if (!kernel.is_open)
		return;
	if (stream->recording.proc.stream_idx != UNINIT_IDX)
		return;
	if (ML_ISSET(ml, NO_RECORDING))
		return;

	len = snprintf(buf, sizeof(buf), "TAG %u MEDIA %u TAG-MEDIA %u COMPONENT %u FLAGS %" PRIu64 " MEDIA-SDP-ID %i",
				   ml->unique_id, media->unique_id, media->index, stream->component,
				   atomic64_get_na(&stream->ps_flags), media->media_sdp_id);
	append_meta_chunk(recording, buf, len, "STREAM %u details", stream->unique_id);

	len = snprintf(buf, sizeof(buf), "tag-%u-media-%u-component-%u-%s-id-%u",
			ml->unique_id, media->index, stream->component,
			(PS_ISSET(stream, RTCP) && !PS_ISSET(stream, RTP)) ? "RTCP" : "RTP",
			stream->unique_id);
	stream->recording.proc.stream_idx = kernel_add_intercept_stream(recording->proc.call_idx, buf);
	if (stream->recording.proc.stream_idx == UNINIT_IDX) {
		ilog(LOG_ERR,
			"recording STREAM    call-id=" STR_FORMAT_M
			"  status=NOT_OPENED   stream=%s  stream_id=%u  err=%s"
			"  | FAILED to add stream to kernel recording interface",
			STR_FMT_M(&call->callid), buf, stream->unique_id, strerror(errno));
		return;
	}
	ilog(LOG_NOTICE,
		"recording STREAM    call-id=" STR_FORMAT_M
		"  status=OPENED       stream=%s  stream_id=%u"
		"  kernel_stream_idx=%u  kernel_call_idx=%u"
		"  tag=%u  media=%u  component=%u"
		"  | Stream registered for kernel intercept /proc recording",
		STR_FMT_M(&call->callid),
		buf, stream->unique_id,
		stream->recording.proc.stream_idx, recording->proc.call_idx,
		ml->unique_id, media->unique_id, stream->component);
	append_meta_chunk(recording, buf, len, "STREAM %u interface", stream->unique_id);
}

static void setup_monologue_proc(struct call_monologue *ml) {
	call_t *call = ml->call;
	struct recording *recording = call->recording;

	if (!recording)
		return;
	if (ML_ISSET(ml, NO_RECORDING))
		return;

	append_meta_chunk_str(recording, &ml->tag, "TAG %u", ml->unique_id);
	update_metadata_monologue_only(ml, NULL);
}

static void setup_media_proc(struct call_media *media) {
	call_t *call = media->call;
	struct recording *recording = call->recording;

	if (!recording)
		return;
	if (ML_ISSET(media->monologue, NO_RECORDING))
		return;

	append_meta_chunk_null(recording, "MEDIA %u PTIME %i", media->unique_id, media->ptime);

	codecs_ht_iter iter;
	t_hash_table_iter_init(&iter, media->codecs.codecs);

	rtp_payload_type *pt;
	while (t_hash_table_iter_next(&iter, NULL, &pt)) {
		append_meta_chunk(recording, pt->encoding_with_params.s, pt->encoding_with_params.len,
				"MEDIA %u PAYLOAD TYPE %u", media->unique_id, pt->payload_type);
		append_meta_chunk(recording, pt->format_parameters.s, pt->format_parameters.len,
				"MEDIA %u FMTP %u", media->unique_id, pt->payload_type);
	}
}



static void dump_packet_proc(struct media_packet *mp, const str *s) {
	struct packet_stream *stream = mp->stream;
	if (stream->recording.proc.stream_idx == UNINIT_IDX)
		return;

	struct rtpengine_command_packet *cmd;
	unsigned char pkt[sizeof(*cmd) + s->len + MAX_PACKET_HEADER_LEN];
	cmd = (void *) pkt;

	cmd->cmd = REMG_PACKET;
	//remsg->packet.call_idx = stream->call->recording->proc.call_idx; // unused
	cmd->packet.stream_idx = stream->recording.proc.stream_idx;

	unsigned int pkt_len = fake_ip_header(cmd->packet.data, mp, s);
	pkt_len += sizeof(*cmd);

	int ret = write(kernel.fd, pkt, pkt_len);
	if (ret < 0)
		ilog(LOG_ERR, "Failed to submit packet to kernel intercepted stream: %s", strerror(errno));
}

static void kernel_info_proc(struct packet_stream *stream, struct rtpengine_target_info *reti) {
	if (!stream->call->recording)
		return;
	if (stream->recording.proc.stream_idx == UNINIT_IDX)
		return;
	ilog(LOG_DEBUG, "enabling kernel intercept with stream idx %u", stream->recording.proc.stream_idx);
	reti->do_intercept = 1;
	reti->intercept_stream_idx = stream->recording.proc.stream_idx;
}

static void meta_chunk_proc(struct recording *recording, const char *label, const str *data) {
	append_meta_chunk_str(recording, data, "%s", label);
}

static int create_spool_dir_all(const char *spoolpath) {
	int ret1, ret2;

	ret1 = rec_pcap_create_spool_dir(spoolpath);
	ret2 = check_main_spool_dir(spoolpath);

	if (ret1 == FALSE || ret2 == FALSE) {
		return FALSE;
	}

	return TRUE;
}

static void init_all(call_t *call) {
	rec_pcap_init(call);
	proc_init(call);
}

static void sdp_after_all(struct recording *recording, GString *s, struct call_monologue *ml,
		enum call_opmode opmode)
{
	sdp_after_pcap(recording, s, ml, opmode);
	sdp_after_proc(recording, s, ml, opmode);
}

static void dump_packet_all(struct media_packet *mp, const str *s) {
	dump_packet_pcap(mp, s);
	dump_packet_proc(mp, s);
}

static void finish_all(call_t *call, bool discard) {
	finish_pcap(call, discard);
	finish_proc(call, discard);
}
