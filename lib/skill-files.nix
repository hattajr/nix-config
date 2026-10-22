# List the files of a skill root that Home Manager should link. Apply reads the
# working tree, untracked files included, so caches and virtualenvs left behind
# by running a skill's own tests must never be linked or taken over.
{ lib }:
let
  junkDirectories = [ "__pycache__" ".pytest_cache" ".ruff_cache" ".mypy_cache" ".venv" ];

  sourceFiles = dir: lib.concatLists (lib.mapAttrsToList (name: type:
    let path = dir + "/${name}"; in
    if type == "directory" then
      (if builtins.elem name junkDirectories then [] else sourceFiles path)
    else if lib.hasSuffix ".pyc" name then []
    else [ path ]) (builtins.readDir dir));
in
root: if builtins.pathExists root then sourceFiles root else []
