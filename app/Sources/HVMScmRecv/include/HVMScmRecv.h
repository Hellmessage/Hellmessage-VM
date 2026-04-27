/*
 * HVMScmRecv: SCM_RIGHTS file descriptor receive helper
 *
 * Bridges POSIX recvmsg + cmsg(SCM_RIGHTS) to Swift, since cmsg accessor
 * macros (CMSG_FIRSTHDR / CMSG_DATA / CMSG_LEN) are not Swift-importable.
 *
 * Used by HVMDisplayQemu.DisplayChannel to receive SURFACE_NEW messages
 * carrying an attached POSIX shm fd alongside the payload bytes.
 */
#ifndef HVM_SCM_RECV_H
#define HVM_SCM_RECV_H

#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Single recvmsg call that fills `buf` (up to `bufsize` bytes) and, if the
 * peer attached an SCM_RIGHTS ancillary message, stores the received fd in
 * `*out_fd`.  When no fd is attached `*out_fd` is set to -1.
 *
 * Return value mirrors recv(2):
 *   >0  number of bytes written into `buf`
 *    0  peer closed the connection (EOF)
 *   -1  error, errno is set
 *
 * If multiple fds were attached (protocol violation), all but the first
 * are silently closed and -1 is returned with errno = EPROTO.
 */
ssize_t hvm_scm_recv_msg(int sock_fd,
                         void *buf,
                         size_t bufsize,
                         int *out_fd);

#ifdef __cplusplus
}
#endif

#endif /* HVM_SCM_RECV_H */
