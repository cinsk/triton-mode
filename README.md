
triton-mode
===========

Prerequisites
-------------

1. Install triton command line tool, and configure Triton profiles.  See [this document](https://docs.joyent.com/public-cloud/api/triton-cli) for the instructions.
2-1. Optionally, install `pssh`.  On Mac, you could do `brew install pssh`.
It is possible to use *triton-mode* without `pssh`, but you will be unable to run a command on multiple machines.  Especially `P` command.
2-2. Install Emacs [ssh](https://github.com/ieure/ssh-el/) package (from MELPA).  If you're not familiar with MELPA, read [here](https://melpa.org/#/getting-started).  This is only required for `P` command.


Installation
------------

I highly advise that you enable the `ssh-agent` before launching Emacs.  Assuming that your private key is in `$HOME/.ssh/id_rsa`, you can just enable this by:

        $ eval "$(ssh-agent)"
        $ ssh-add $HOME/.ssh/id_rsa

Download this package using:

        $ git clone https://github.com/cinsk/triton-mode.git

Assuming that triton-mode/ is placed in `~/triton-mode`, add following sexp to your Emacs init file:

        (add-to-list 'load-path (expand-file-name "~/triton-mode"))
        (require 'triton-mode)

Usage
-----

`M-x triton` will launch a buffer per Triton profile.  It will first ask you to select the profile.  For the demonstration purpose, we're going to use the profile, `us-east-1`.   Be patient for a moment as it first try to retrieve required information from the Triton.  Once it is loaded, it will cache the information for a while for the later use.  You may control the cache expiration by updating `triton-buffer-expiration` variable if required.

If everything goes well, you'll see the Emacs buffer like this:

        Joyent Triton at us-east-1

        * Bastion machine SSH port: 22
        * Bastion machine name: bastion
        * Overridden Bastion user name: nil
        * SSH port for machines: 22
        * Overriden Machine user name: nil
        * Use Bastion on public machine: nil

        M INSTANCE IMAGE                  PACKAGE              UPDATED
        - -------- ---------------------- -------------------- ----------------
          70db2402 centos-7               g4-general-4G        2017-09-28 21:58 bastion
          d7201136 d13bd654               k4-highcpu-kvm-3.75G 2018-01-09 08:14 freebsd
          f562d519 freebsd-10             k4-highcpu-kvm-3.75G 2018-01-09 10:39 freebsd-10
          af359c18 centos-7               g4-general-4G        2017-11-16 23:03 kafka1
          2981f890 centos-7               g4-general-4G        2017-09-27 18:03 kafka2
          7d670f65 centos-7               g4-general-4G        2017-09-27 18:03 kafka3
          94dd157d centos-7               k4-highcpu-kvm-3.75G 2018-02-12 22:00 kcentos
          ef1c7b92 ubuntu-certified-16.04 k4-highcpu-kvm-750M  2018-02-12 22:00 kubuntu
          19a154e6 base-64                g4-highcpu-8G        2017-09-08 00:20 smartos

The interface is very similar to *dired* buffer, so that you can navigate using `p` (previous-line) and `n` (next-line).  The lines start with `*` are showing some configuration parameters that are used for the connection to the machines.  Navigate to one of these lines, and pressing `RET` will allow to you update the configuration.

You can *mark* one or more machines using `m`, toggle marks using `t`, unmark all using `U`.

### SSH to a machine

You can create SSH seesion to a machine by pressing `S`.  If there is one or more marked machines, it will select the first marked machine, otherwise it will use the machine on the current line.

If the machine does not have a public IP address, it will first connect to the bastion machine (or jump host) to connect the machine.  You need to specify the name of the bastion machine in the configuration above.  By default, it has the name, "bastion".

The major mode of SSH sessions is `term-mode`.  By default, the terminal mode is the line mode, so that behavior is similar to the `M-x shell`, but you can switch to chararacter mode by pressing `C-c C-k` which enables you to run a program like `top` or even `vim`.  To switch to line mode back again, press `C-c C-j`.  (See also the [documentation of term mode](https://www.gnu.org/software/emacs/manual/html_node/emacs/Term-Mode.html).)

In a SSH buffer, you may use `C-c C-J` (`J` in capital) to switch back to triton buffer.  (If the frame of Emacs is in tty mode, this may not work.)

### Executing a command to multiple machines using pSSH

You can run a command on one or more marked machines parallely.  Pressing (capital) `P` let you specify the command-line, then triton-mode will execute that command (using `pssh) to multiple machines.

If the bastion machine is there, this command will work smoothly even if one of the marked machine does not have a public IP address.

*NOTE*  Each output (stdout and stderr) from a machine is concatenated, and printed using `-i` option of pssh.  You should not run either a command that could generate huge output or a command that could take a significant time.   If you truly want to run a such a command, I suggest you use [triton-pssh](https://github.com/cinsk/triton-pssh).

All output is appended in *triton-pssh* buffer.  For example, here's the output of running `uptime` in three marked machines:

        [1] 10:48:11 [SUCCESS] root@72.9.119.52
         17:48:11 up 30 days, 20:26,  0 users,  load average: 0.00, 0.00, 0.00
        [2] 10:48:11 [SUCCESS] root@72.5.118.31
         17:48pm  up 245 days 17:28,  0 users,  load average: 0.00, 0.00, 0.00
        [3] 10:48:11 [SUCCESS] root@192.168.128.72
         5:48PM  up 122 days,  7:08, 0 users, load averages: 0.24, 0.15, 0.12
        ^L

Each run is delimited by `\f\n`, so that you can navigate using `C-x [` and `C-x ]`.  Per machine output is treated as a function, so that you can nagivated using `C-M-a` and `C-M-e`.


TODO
----

Here are some additional task(s) that need to be done.   Any help will be appriciated:

1. Add more configurations in triton buffer such as `triton-use-ssh-agent-forwarding`.
2. Convert most `defvar` to `defcustom` styles for better configuration management.
3. To upload this package to MELPA or other Emacs package repository
   package.
4. Implements feature to launch/stop/update Triton Compute instances.
5. Remove dependency to Emacs `ssh` package.  /triton-mode/ only needs this package for the function, `ssh-parse-words`.
6. Ability to inject data (probably in a kill ring) to each machine in PSSH.
7. Update this README in a nice/proper English.
8. Optimize a PSSH command interface if there are too many marked machines.

