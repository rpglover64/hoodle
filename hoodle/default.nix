{ mkDerivation, base, cmdargs, configurator, containers, directory
, filepath, hoodle-core, mtl, stdenv
}:
mkDerivation {
  pname = "hoodle";
  version = "0.4.0";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  buildDepends = [
    base cmdargs configurator containers directory filepath hoodle-core
    mtl
  ];
  homepage = "http://ianwookim.org/hoodle";
  description = "Executable for hoodle";
  license = stdenv.lib.licenses.gpl3;
}
