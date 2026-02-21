# ajail

a basic, simplistic jail for running programs you don't completely trust. ajail
is just a nice helper around 
[bubblewrap](https://github.com/containers/bubblewrap). 

instead of making a complex jail environment with many features, the goal here 
to have something simple that you can audit by hand very quickly. it is
currently ~ 300 lines of clean python.

## high level picture

ajail is a bubblewrapped chroot. you store the immutable root filesystem named 
`name` in `~/.ajail/fs/<name>`, where `<name>` is `default` if `--fs=name` isn't
specified.

when you run `ajail <command>` in a folder, a bubblewrapped, chrooted
environment is started with the defaut root filesystem, with the current
directory mounted inside. the root fs is mounted read only with a read/write
temporary overlay fs, and the current directory is mounted read/write or read 
only with a temporary overlay fs, depending on your arguments.

inside the bubblewrapped, chrooted environment, your UID/GID are mapped to
appear as root through the magic of linux namespacing. inside the jail,
everything appears root owned, and processes appear to have root privileges. in
reality, they only have access to what you've allowed them to have, and root
operations inside the jail appear as your UID outside the jail.

the key feature this combo of things provides is that inside the jail, system
packages can be installed ephemerally. `apk add nodejs` or `apt install nodejs`
will install `nodejs` but it will disappear next session. the same applies to
changes to `$HOME`.

note that inside the jail, `$HOME` is `/root`, which can be found (and persisted
with `--home-edit` or `--fs-edit`) at `~/.ajail/fs/<name>/root`.

## cloning

one special feature is `--clone`, which, if run inside a folder that is a source
repository (e.g. a Git repo), instead of mounting it directly will make a clone
with the current directory repository as the upstream, and mount that instead.
this is extremely useful for running multiple AI agents concurrently.

## remote access

remote access is outside of the scope of this specific project, but is 
extremely easy to set up. you can run
[singleuser-sshd](https://github.com/jtolio/singleuser-sshd) inside the jail,
and then connect to that externally (either directly or through a tailnet or 
something).

## setup

ajail comes with a script per distro. currently supported distros in `mkfs/`
are Alpine, Arch, Debian, Nix, Ubuntu, Void, and Wolfi. each script creates a rootfs in
the given target folder. you use them like

```
sudo ./mkfs/alpine.sh -u $(whoami) ~/.ajail/fs/alpine -p nano
```

or

```
sudo ./mkfs/debian.sh -u $(whoami) ~/.ajail/fs/deb -p vim,build-essential
```

ajail does not create a full user id namespace, but instead just maps your uid
to root. because of this, there are no users other than root inside the jail.
this makes some package installations a little unhappy, but most standard
distribution packages can install cleanly in your environment.

for a basic setup, run

```
sudo ./mkfs/wolfi.sh -u $(whoami) ~/.ajail/fs/default -p \
  build-base,go,python3,py3-pip,nodejs,npm,wget,curl,git
```

## usage

```
ajail - a simple script to make using bubblewrap in a folder easier.

usage: ajail [OPTION]... [<COMMAND>...]

 --fs=<ROOT_FS>           specify the root fs to use. by default uses 'default'.
                          if ROOT_FS is not an absolute path, the name is looked
                          for at ~/.ajail/fs/<ROOT_FS>.
 --ro[=<DIR>]             wrap the provided directory in a temporary rw overlay.
                          if no directory is specified, cwd is assumed. DIR can
                          be absolute or relative. see --rw and --hide.
 --rw[=<DIR>]             make changes to the provided directory persistent.
 --hide[=<DIR>]           make the provided directory appear empty.
 --mount=<SRC>,<DST>[,rw] mount SRC at DST. mounted with a temporary rw overlay
                          on top unless rw is provided for persistence.
 --fs-edit[=<DIR>]        make changes to the root filesystem persistent. if
                          <DIR> is provided, just that subtree.
 --home-edit[=<SUBDIR>]   a subset of --fs-edit, make just jail-home changes
                          persistent, optionally just a subdirectory.
 --no-net                 disable network access.
 --clone                  if the current directory is a source repository,
                          instead of mounting the current directory directly,
                          we will make a new clone of the source repository
                          and mount that. pushing from inside will update the
                          current directory's metadata.
 --quiet                  no status output

if [<command>...] is not provided, defaults to 'bash -l'.
```

here is how to run a command (`sh`) in the default rootfs with the current
directory mounted read/write:

```
ajail sh
```

* to use another rootfs, specify `--fs=fsname` before the command.
* to make changes to the current directory ephemeral, add `--ro` before the
  command. note that `--ro` does not mean the directory will be read-only
  inside the jail, but it does mean changes won't make it outside of the
  jail. from the perspective of the outside of the jail, the jail will
  only read the folder.
* to mount just a subdirectory , such as `.git`, add `--ro=.git` before
  the command. multiple `--ro=` arguments and `--rw=` arguments can be provided,
  processed in the order they are received. `--ro=` means the subdirectory
  will be ephemeral, `--rw=` means the subdirectory will be persistent.
  layering `--rw=` on top of an `--ro=` path allows you to punch a persistent
  hole in an otherwise ephemeral place.
* to make a directory appear empty (hide git history or something) you can do
  `--hide=dir`, like `--hide=.git`.
* `--ro=`, `--rw=` are both just special forms of `--mount`.
* if you want to mount the rootfs so you can make persistent changes to it,
  you can add `--fs-edit`
* you can disallow network access using `--no-net`

## environment variable control

ajail also respects the environment variable `AJAIL_ARGS`, which is a set of
arguments separated by semicolon. any argument ajail understands can also
be provided via this environment variable. `AJAIL_ARGS` is evaluated first, so
arguments specified on the commandline are processed after and thus take
precedence. this feature can be useful for changing the default behavior
(e.g., change the default root fs by setting `AJAIL_ARGS=--fs=newdefault`) in
certain directories or contexts using something like
[direnv](https://github.com/direnv/direnv).

ajail strips the environment before passing it into the jail down to the bare
minimum, but you can specify environment variables you do want to go into the
jail by using environment variables prefixed with `AJAIL_ENV_`. if you want
to specify the `$PATH` or something else to be something different, you can set
`AJAIL_ENV_PATH` and it will override the default.

## example:

this will run Claude Code in the current directory without write access to
`./.git`, but with write access to Claude's settings:

```
ajail --ro=.git --home-edit=.claude --home-edit=.claude.json claude
```

(note that you will need to install and configure claude with `--fs-edit`
once first)

this will install vim into a debian based rootfs (`--fs-edit` makes it
persistent):

```
ajail --fs-edit apt install vim
```

this will start claude with its own clone of the current repo (be sure to
tell it to push to another branch):

```
ajail --clone claude
```

this will start ajail with nothing but the root fs mounted ro:

```
ajail --hide
```

## LLM disclaimer:

ajail is human-written (but with light advice and suggestions from an LLM).
mkfs/*.sh were created with the help of an LLM.

## requirements:

* linux kernel >= 5.13 (overlayfs in user namespaces)
* python >= 3.9
* [bubblewrap](https://github.com/containers/bubblewrap) >= 0.11.0
  (`sudo dnf install bubblewrap` or `sudo apt install bubblewrap`)
* debootstrap for `mkfs/debian.sh` and `mkfs/ubuntu.sh`

## license

MIT
