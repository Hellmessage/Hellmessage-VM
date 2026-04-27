/*
 * HVMScmRecv: SCM_RIGHTS file descriptor receive helper.
 * See include/HVMScmRecv.h for API contract.
 */
#include "HVMScmRecv.h"

#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>

ssize_t hvm_scm_recv_msg(int sock_fd,
                         void *buf,
                         size_t bufsize,
                         int *out_fd)
{
    if (out_fd == NULL) {
        errno = EINVAL;
        return -1;
    }
    *out_fd = -1;

    struct iovec iov;
    iov.iov_base = buf;
    iov.iov_len  = bufsize;

    /* Buffer large enough for a single SCM_RIGHTS fd. */
    union {
        struct cmsghdr cmsg;
        char           pad[CMSG_SPACE(sizeof(int))];
    } cbuf;
    memset(&cbuf, 0, sizeof(cbuf));

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov        = &iov;
    msg.msg_iovlen     = 1;
    msg.msg_control    = cbuf.pad;
    msg.msg_controllen = sizeof(cbuf.pad);

    ssize_t n;
    do {
        n = recvmsg(sock_fd, &msg, 0);
    } while (n < 0 && errno == EINTR);
    if (n <= 0) {
        return n;
    }

    /* Walk the cmsg list looking for SCM_RIGHTS. */
    for (struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);
         cm != NULL;
         cm = CMSG_NXTHDR(&msg, cm)) {
        if (cm->cmsg_level != SOL_SOCKET ||
            cm->cmsg_type  != SCM_RIGHTS) {
            continue;
        }
        size_t cmsg_payload = (size_t)cm->cmsg_len -
                              (size_t)((char *)CMSG_DATA(cm) - (char *)cm);
        size_t fd_count = cmsg_payload / sizeof(int);
        if (fd_count == 0) {
            continue;
        }
        int fds[fd_count];
        memcpy(fds, CMSG_DATA(cm), fd_count * sizeof(int));
        *out_fd = fds[0];
        if (fd_count > 1) {
            /* protocol violation: more than one fd attached */
            for (size_t i = 1; i < fd_count; i++) {
                close(fds[i]);
            }
            close(fds[0]);
            *out_fd = -1;
            errno = EPROTO;
            return -1;
        }
    }

    return n;
}
