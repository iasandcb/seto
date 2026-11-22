//! Where a loaded `seto_tsf.dll` looks for dictionaries.
//!
//! Each install uses its own folder named after the DLL (`seto_tsf-<stamp>\Resources`
//! beside `seto_tsf-<stamp>.dll`). A running process keeps `korean-valid.txt`
//! memory-mapped, so the next update must not reuse that file.

use std::path::{Path, PathBuf};

pub fn lexicon_directories(dll: Option<&Path>, local_seto: Option<&Path>) -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Some(dll) = dll
        && let Some(dir) = dll.parent()
    {
        if let Some(stem) = dll.file_stem() {
            let beside = dir.join(stem);
            dirs.push(beside.join("Resources"));
            dirs.push(beside);
        }
        dirs.push(dir.join("Resources"));
        dirs.push(dir.to_path_buf());
    }
    if let Some(base) = local_seto {
        push_unique(&mut dirs, base.join("Resources"));
        push_unique(&mut dirs, base.to_path_buf());
    }
    dirs
}

fn push_unique(dirs: &mut Vec<PathBuf>, path: PathBuf) {
    if !dirs.iter().any(|dir| dir == &path) {
        dirs.push(path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versioned_folder_beside_the_dll_comes_first() {
        let dll = PathBuf::from("Seto").join("seto_tsf-20261121-160900.dll");
        let local = PathBuf::from("Seto");
        let dirs = lexicon_directories(Some(&dll), Some(&local));
        let stem = PathBuf::from("Seto").join("seto_tsf-20261121-160900");
        assert_eq!(dirs[0], stem.join("Resources"));
        assert_eq!(dirs[1], stem);
        assert!(dirs.iter().any(|dir| dir == &local.join("Resources")));
        assert_eq!(dirs.iter().position(|dir| dir.ends_with("Resources")).unwrap(), 0);
    }
}
