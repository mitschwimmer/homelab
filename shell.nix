{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  packages = [
    pkgs.opentofu
    pkgs.incus.client
    pkgs.authelia
    (pkgs.python3.withPackages (ps: with ps; [ pykeepass cryptography ]))
  ];
}
