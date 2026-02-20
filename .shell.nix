{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
	packages = with pkgs; [
		luajit
		lua
		lua-language-server
	];
}
