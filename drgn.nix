{
  pkgs,
  python3Packages,
  fetchFromGitHub,
}:

python3Packages.buildPythonApplication rec {
  name = "drgn";
  version = "0.2.0";
  pyproject = true;

  nativeBuildInputs = with pkgs; [
    autoconf
    automake
    libtool
    pkg-config
  ];

  buildInputs = with pkgs; [
    elfutils
    python3Packages.setuptools
  ];

  src = fetchFromGitHub {
    owner = "osandov";
    repo = "${name}";
    tag = "v${version}";
    hash = "sha256-RyMWHiNfpJ6gAefXVB5cQKbtXQzBEJ+0syPsry2me1I=";
  };
}
