应当将 bash 理解为 GNU Shell，正如 Bash 主页第一句话 Bash is the GNU Project's shell — the Bourne Again SHell. 这句话的中心是 GNU Project's Shell.
所谓 GNU/Linux 系统，我理解为 GNU 作为 userland 的基础，Linux 作为 kernel 的操作系统。

GNU 体系的核心软件有

- Textinfo 软件文档，注意 man 是 Unix 引入的
- GRUB Bootloader，Debian/Ubuntu 使用，而 Arch/Fedora/OpenSUSE 等使用 systemd-boot
- Bash
- Coreutils

另外注意 bootloader 不算 userland，userland 指的是 bootloader/firmware/kernel 以外的软件。
