所谓 GNU/Linux 系统，我理解为 GNU 作为 userland 的基础，Linux 作为 kernel 的操作系统。

GNU 体系的核心软件有

- Textinfo 软件文档，注意 man 是 Unix 引入的
- GRUB Bootloader，Debian/Ubuntu 使用，而 Arch/Fedora/OpenSUSE 等使用 systemd-boot
- Bash
- Coreutils
- gzip
- tar

另外 GNU Toolchain 包括

- make
- gcc
- glibc
- Binutils
- gdb
- bison
- m4

另外 GNU Build System 包括 autoconf，automake，libtool。

其他知名软件包括 Emacs，wget，nano，GIMP，gnuplot。GNOME 也源于 GNU。

另外注意 bootloader 不算 userland，userland 指的是 bootloader/firmware/kernel 以外的软件。
