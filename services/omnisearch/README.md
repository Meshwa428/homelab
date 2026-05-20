# OmniSearch

A modern lightweight metasearch engine with a clean design written in C.

## Disclaimer
I request that none of this code, in part or in full, be hosted on GitHub, SourceForge, or any other proprietary platform. This request is made out of respect for both me, the developer and for you, the user.

## Configuration
Create a config.ini, there is an example included in the root. Or if you installed omnisearch, edit the installed config file.

## Dependencies
- libxml2
- libcurl (may be replaced in the future with curl-impersonate)
- beaker [(source)](https://git.bwaaa.monster/beaker/)

## First Setup
Depending on your system, you may first need to install libcurl and libxml2.

### Arch Linux
```
# pacman -S libxml2 curl
```

### Debian/Ubuntu
```
# apt install build-essential libssl-dev libxml2-dev libcurl4-openssl-dev
```

### Fedora
```
# dnf install libxml2-devel libcurl-devel
```

### openSUSE
```
# zypper install libxml2-devel libcurl-devel
```

### Alpine
```
# apk add libxml2-dev curl-dev shadow
```
On Alpine, `shadow` is needed for the user creation process during the install.

### Void
```
# xbps-install -S libxml2-devel libcurl-devel
```

### NixOS
Add the flake to your inputs and import the module. That is all you need.
Here's an example of using the modules in a flake:
```nix
# flake.nix
{
  inputs = {
    omnisearch = {
      url = "git+https://git.bwaaa.monster/omnisearch";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, omnisearch, ... }: {
    nixosConfigurations.mySystem = nixpkgs.lib.nixosSystem {
      modules = [
        omnisearch.nixosModules.default
        {
          services.omnisearch.enable = true;
        }
      ];
    };
  };
}
```

### macOS (Homebrew)
```
$ brew install libxml2 curl openssl pkg-config
```

### macOS (MacPorts)
```
# port install libxml2 curl openssl3 pkgconfig
```

On macOS the build uses `pkg-config` to discover `libxml2`, `libcurl` and OpenSSL flags.

Install libbeaker:
```
$ git clone https://git.bwaaa.monster/beaker
$ cd beaker
$ make
# make install
```

On macOS `beaker` installs to `/usr/local/` by default and installs `libbeaker.dylib`.

And then install omnisearch:
```
$ git clone https://git.bwaaa.monster/omnisearch
$ cd omnisearch
$ make
# make install-<init>
```
Replace `<init>` with your init system (`openrc`, `systemd`, `runit`, `s6`, `dinit`, `launchd`).
On macOS, use `install-launchd`.

## Hosting
Run it normally behind a reverse proxy (like nginx)

## Deploy with Docker Compose

You need Docker or Podman and Docker Compose installed on your system.

Run the container:

```
$ git clone https://git.bwaaa.monster/omnisearch
$ cd omnisearch
$ docker compose up -d --build
```

By default it can be reached on port 8087.

## Customisation
To make your own changes while still being able to receive upstream updates:

```
$ git checkout -b my-changes
```

Make your changes in the cloned folder, then periodically merge upstream:

```
$ git fetch origin
$ git merge origin/master
```

If there are conflicts in the files you modified, resolve them manually. You should also make the changes to the cloned repository, and then run the install command again if you installed omnisearch. Changes made directly to the configuration/assets folder will be overwritten on reinstall.

## Contribution
Generate a patch with ```git format-patch HEAD~1``` and email to [gabriel@bwaaa.monster](mailto:gabriel@bwaaa.monster), beginning the subject line with [PATCH omnisearch] 

*If you are sending a revised version of a previous patch, please use [PATCH omnisearch v2, v3, etc].*
