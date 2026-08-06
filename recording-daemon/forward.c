#include "forward.h"
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>
#include "main.h"
#include "log_r.h"

void start_forwarding_capture(metafile_t *mf, char *meta_info) {
	int sock;
	struct sockaddr_un addr;

	if (mf->forward_fd >= 0) {
		ilog(LOG_INFO, "Connection already established");
		return;
	}

#ifdef SOCK_SEQPACKET
	if ((sock = socket(AF_UNIX, SOCK_SEQPACKET, 0)) == -1) {
#else
	if ((sock = socket(AF_UNIX, SOCK_DGRAM, 0)) == -1) {
#endif
		ilog(LOG_ERR, "Error creating socket: %s call-id=%s%s%s",
			strerror(errno),
			FMT_M(mf && mf->call_id ? mf->call_id : "(unknown)"));
		return;
	}

	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, forward_to, sizeof(addr.sun_path) - 1);

	if (fcntl(sock, F_SETFL, O_NONBLOCK) < 0) {
		ilog(LOG_ERR, "Error setting socket non-blocking: %s call-id=%s%s%s",
			strerror(errno),
			FMT_M(mf && mf->call_id ? mf->call_id : "(unknown)"));
		goto err;
	}

	if (connect(sock, (struct sockaddr*) &addr, sizeof(addr)) == -1) {
		ilog(LOG_ERR, "recording lifecycle: event=forward-connect call-id=%s%s%s path=%s err=%s result=failed",
			FMT_M(mf && mf->call_id ? mf->call_id : "(unknown)"),
			addr.sun_path,
			strerror(errno));
		goto err;
	}

	if (send(sock, meta_info, strlen(meta_info), 0) == -1) {
		ilog(LOG_ERR, "Error sending meta info: %s. Call will not be forwarded call-id=%s%s%s",
			strerror(errno),
			FMT_M(mf && mf->call_id ? mf->call_id : "(unknown)"));
		goto err;
	}

	ilog(LOG_NOTICE, "recording lifecycle: event=forward-connect call-id=%s%s%s path=%s result=success",
		FMT_M(mf && mf->call_id ? mf->call_id : "(unknown)"),
		addr.sun_path);

	mf->forward_fd = sock;
	return;
err:
	close(sock);
}

int forward_packet(metafile_t *mf, unsigned char *buf, unsigned len) {

	if (mf->forward_fd == -1) {
		ilog(LOG_ERR,
				"Trying to send packets, but connection not initialized! call-id=%s%s%s",
				FMT_M(mf && mf->call_id ? mf->call_id : "(unknown)"));
		goto err;
	}

	if (send(mf->forward_fd, buf, len, 0) == -1) {
		if (errno == EAGAIN || errno == EWOULDBLOCK)
			ilog(LOG_DEBUG, "Dropping packet since call would block");
		else
			ilog(LOG_ERR, "Error sending: %s call-id=%s%s%s",
				strerror(errno),
				FMT_M(mf && mf->call_id ? mf->call_id : "(unknown)"));
		goto err;
	}

	return 0;

err:
	return -1;
}

