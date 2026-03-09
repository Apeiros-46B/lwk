{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
	packages = with pkgs; [
		rlwrap
		luajit
		lua
		lua-language-server
	];
}
