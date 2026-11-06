//! Document location and saved revision tracking. Identity is not an atomic CAS.
use std::{
    fs, io,
    path::{Path, PathBuf},
    time::SystemTime,
};
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileIdentity {
    pub len: u64,
    pub modified: Option<SystemTime>,
    pub content_hash: u64,
}
impl FileIdentity {
    pub fn read(path: &Path) -> io::Result<Self> {
        let m = fs::metadata(path)?;
        use std::{hash::Hasher, io::Read};
        let mut file = fs::File::open(path)?;
        let mut hash = std::collections::hash_map::DefaultHasher::new();
        let mut buffer = [0u8; 65536];
        loop {
            let n = file.read(&mut buffer)?;
            if n == 0 {
                break;
            }
            hash.write(&buffer[..n]);
        }
        Ok(Self {
            len: m.len(),
            modified: m.modified().ok(),
            content_hash: hash.finish(),
        })
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DocumentLocation {
    pub path: PathBuf,
    pub format: String,
    pub identity: FileIdentity,
}
#[derive(Clone, Debug)]
pub struct SaveSnapshot {
    pub revision: u64,
    pub bytes: Vec<u8>,
}
#[derive(Clone, Debug, Default)]
pub struct DocumentSession {
    location: Option<DocumentLocation>,
    saved_revision: Option<u64>,
}
impl DocumentSession {
    pub fn opened(path: PathBuf, format: String, revision: u64) -> io::Result<Self> {
        let identity = FileIdentity::read(&path)?;
        Ok(Self {
            location: Some(DocumentLocation {
                path,
                format,
                identity,
            }),
            saved_revision: Some(revision),
        })
    }
    pub fn location(&self) -> Option<&DocumentLocation> {
        self.location.as_ref()
    }
    pub fn saved_revision(&self) -> Option<u64> {
        self.saved_revision
    }
    pub fn externally_changed(&self) -> io::Result<bool> {
        match &self.location {
            Some(l) => match FileIdentity::read(&l.path) {
                Ok(now) => Ok(now != l.identity),
                Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(true),
                Err(e) => Err(e),
            },
            None => Ok(false),
        }
    }
    /// Record only after successful publication; later edits remain dirty.
    pub fn published(&mut self, path: PathBuf, format: String, revision: u64) -> io::Result<()> {
        let identity = FileIdentity::read(&path)?;
        self.location = Some(DocumentLocation {
            path,
            format,
            identity,
        });
        self.saved_revision = Some(revision);
        Ok(())
    }
    pub fn is_dirty(&self, revision: u64) -> bool {
        self.saved_revision != Some(revision)
    }
}

/// Write and flush a temporary sibling before publishing it. Existing files are
/// replaced only if their last observed identity matches. The check and replace
/// are separate filesystem operations and do not provide atomic compare-and-swap.
pub fn publish(
    path: &Path,
    bytes: &[u8],
    expected: Option<&FileIdentity>,
) -> io::Result<FileIdentity> {
    use std::io::Write;
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    temporary.write_all(bytes)?;
    temporary.flush()?;
    temporary.as_file().sync_all()?;
    match expected {
        None => {
            temporary.persist_noclobber(path).map_err(|e| e.error)?;
        }
        Some(expected) => {
            if FileIdentity::read(path)? != *expected {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "Destination changed since it was opened or confirmed",
                ));
            }
            replace_existing(temporary.path(), path)?;
        }
    }
    FileIdentity::read(path)
}
#[cfg(not(windows))]
fn replace_existing(source: &Path, destination: &Path) -> io::Result<()> {
    fs::rename(source, destination)
}
#[cfg(windows)]
fn replace_existing(source: &Path, destination: &Path) -> io::Result<()> {
    use std::{os::windows::ffi::OsStrExt, ptr::null};
    use windows_sys::Win32::Storage::FileSystem::ReplaceFileW;
    let src: Vec<u16> = source.as_os_str().encode_wide().chain(Some(0)).collect();
    let dst: Vec<u16> = destination
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    let ok = unsafe { ReplaceFileW(dst.as_ptr(), src.as_ptr(), null(), 0, null(), null()) };
    if ok == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn publication_rejects_conflicts_and_tracks_snapshot_revision() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("document");
        let first = publish(&path, b"original", None).unwrap();
        let mut session = DocumentSession::opened(path.clone(), "test".into(), 1).unwrap();
        assert!(!session.is_dirty(1));
        assert!(publish(&path, b"no clobber", None).is_err());
        fs::write(&path, b"external modification").unwrap();
        assert!(session.externally_changed().unwrap());
        assert!(publish(&path, b"edited", Some(&first)).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"external modification");
        let confirmed = FileIdentity::read(&path).unwrap();
        publish(&path, b"edited", Some(&confirmed)).unwrap();
        session.published(path.clone(), "test".into(), 2).unwrap();
        assert!(!session.is_dirty(2));
        assert!(session.is_dirty(3));
        assert_eq!(fs::read(path).unwrap(), b"edited");
    }
}
