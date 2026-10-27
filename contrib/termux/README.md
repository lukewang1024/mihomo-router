# Android linker tracing and SSH forwarding

On an affected Android/Termux device, an SSH connection authenticated successfully
but failed opening forwarding channels. OpenSSH reported `Bad packet length`;
Mihomo reported `ssh: unexpected packet in response to channel open: <nil>`.
A TCP relay captured an unencrypted `B|<pid>|dlclose` trace record in the SSH
stream. The fault also reproduced using an ordinary OpenSSH client on the same
phone, independently of the router, and remained after updating OpenSSH.

The Android linker caches the descriptor used for `trace_marker`. SSH's descriptor
cleanup can close it, then reuse its number for the transport. Subsequent linker
tracing writes to the wrong descriptor. `preserve-trace-fd.c` interposes `close`
to retain only the two standard kernel trace-marker paths. All other descriptors
are closed using the kernel syscall. It does not filter network bytes or change
global trace settings. This workaround is scoped to the SSH daemon and its helper
processes; it is not a general preload for applications.

Build on the phone (requires clang), keeping the source checkout separate from
machine-local data:

```sh
ssh_data=${XDG_DATA_HOME:-$HOME/.local/share}/mihomo-router/phone-ssh
mkdir -p "$ssh_data"
clang -shared -fPIC -O2 -Wall -Wextra -Werror \
  contrib/termux/preserve-trace-fd.c -o "$ssh_data/preserve-trace-fd.so"
clang -O2 -Wall -Wextra -Werror contrib/termux/test-close.c -o "$ssh_data/test-close"
LD_PRELOAD="$ssh_data/preserve-trace-fd.so" "$ssh_data/test-close"
```

Back up the existing Termux runit SSH service run file. Immediately before its
existing `exec sshd ...` line, add these POSIX shell statements (expand the data
path appropriately if XDG_DATA_HOME is set in a login shell but not in runit):

```sh
ssh_data=${XDG_DATA_HOME:-$HOME/.local/share}/mihomo-router/phone-ssh
LD_PRELOAD=$ssh_data/preserve-trace-fd.so${LD_PRELOAD:+:$LD_PRELOAD}
export LD_PRELOAD
```

Keep existing service flags and inherited environment, including configured
network proxy variables. Validate the run script and reload/restart the existing
SSH service. Verify ordinary descriptor closure and actual SSH forwarding,
including an internal numeric target and a domain over HTTPS. A compile or parser
check alone does not prove the tunnel works. Keep host-key pinning and restricted,
dedicated gateway credentials. Recheck the service run file after package updates.

To undo, restore the backed-up run file and restart the SSH daemon; leave global
Android tracing under the user's control. If tracing is inactive, the positive
trace-descriptor test can report zero; live SSH acceptance remains necessary.
