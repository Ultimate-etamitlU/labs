import os


def close_inherited_fds():
    """Close inherited descriptors so terminal children cannot retain the portal socket."""
    try:
        inherited = [int(name) for name in os.listdir("/proc/self/fd")]
    except (OSError, ValueError):
        inherited = range(3, 1024)
    for fd in inherited:
        if fd < 3:
            continue
        try:
            os.close(fd)
        except OSError:
            pass
