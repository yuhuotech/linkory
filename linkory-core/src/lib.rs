//! Same-network direct transfer, wire protocol `LNK1` (see `linkory-protocol/PROTOCOL.md`).
//!
//! Both ends share a per-task 32-byte secret delivered by the server over their authenticated
//! sessions. The handshake proves possession of it in both directions before any file byte moves;
//! file bytes are then sent as ChaCha20-Poly1305 frames. `offset` lets a receiver that already
//! holds a prefix (an interrupted attempt) resume.
//!
//! This crate is the reference implementation of the protocol; the Flutter client currently ships
//! an equivalent Dart implementation and the two are checked against each other in CI-style tests.

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::time::Duration;

use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use rand::RngCore;
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

pub const MAGIC: &[u8; 4] = b"LNK1";
pub const CHUNK: usize = 256 * 1024;
const MAX_FRAME: usize = CHUNK + 64;
const T_DATA: u8 = 0;
const T_END: u8 = 1;

type HmacSha256 = Hmac<Sha256>;

fn err(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg.to_string())
}

fn proof(secret: &[u8; 32], role: u8, id: &[u8; 16], ns: &[u8; 16], nr: &[u8; 16], offset: u64) -> [u8; 32] {
    let mut m = <HmacSha256 as Mac>::new_from_slice(secret).expect("hmac key");
    m.update(&[role]);
    m.update(id);
    m.update(ns);
    m.update(nr);
    m.update(&offset.to_be_bytes());
    m.finalize().into_bytes().into()
}

struct Aead_ {
    c: ChaCha20Poly1305,
    n: u64,
}

impl Aead_ {
    fn derive(secret: &[u8; 32], ns: &[u8; 16], nr: &[u8; 16]) -> Self {
        let mut salt = [0u8; 32];
        salt[..16].copy_from_slice(ns);
        salt[16..].copy_from_slice(nr);
        let hk = Hkdf::<Sha256>::new(Some(&salt), secret);
        let mut key = [0u8; 32];
        hk.expand(b"linkory-lan-v1", &mut key).expect("hkdf len");
        Aead_ { c: ChaCha20Poly1305::new(Key::from_slice(&key)), n: 0 }
    }
    fn nonce(&mut self) -> Nonce {
        let mut b = [0u8; 12];
        b[4..].copy_from_slice(&self.n.to_be_bytes());
        self.n += 1;
        *Nonce::from_slice(&b)
    }
    fn seal(&mut self, ty: u8, payload: &[u8]) -> Vec<u8> {
        let mut plain = Vec::with_capacity(1 + payload.len());
        plain.push(ty);
        plain.extend_from_slice(payload);
        let n = self.nonce();
        self.c.encrypt(&n, plain.as_slice()).expect("encrypt")
    }
    fn open(&mut self, frame: &[u8]) -> io::Result<(u8, Vec<u8>)> {
        let n = self.nonce();
        let plain = self.c.decrypt(&n, frame).map_err(|_| err("bad frame (auth failed)"))?;
        if plain.is_empty() {
            return Err(err("empty frame"));
        }
        Ok((plain[0], plain[1..].to_vec()))
    }
}

fn write_frame(w: &mut impl Write, f: &[u8]) -> io::Result<()> {
    w.write_all(&(f.len() as u32).to_be_bytes())?;
    w.write_all(f)
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum SendOutcome {
    Ok,
    Rejected,
}

/// Connects to the receiver and streams `file` from the offset the receiver reports.
pub fn send(
    addr: impl ToSocketAddrs,
    task_id: &[u8; 16],
    secret: &[u8; 32],
    file: &Path,
    mut on_progress: impl FnMut(u64),
) -> io::Result<SendOutcome> {
    let sa: SocketAddr = addr.to_socket_addrs()?.next().ok_or_else(|| err("no address"))?;
    let mut s = TcpStream::connect_timeout(&sa, Duration::from_secs(2))?;
    s.set_nodelay(true)?;
    s.set_read_timeout(Some(Duration::from_secs(30)))?;
    let mut ns = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut ns);
    s.write_all(MAGIC)?;
    s.write_all(task_id)?;
    s.write_all(&ns)?;
    let mut head = [0u8; 16 + 8 + 32];
    s.read_exact(&mut head)?;
    let nr: [u8; 16] = head[..16].try_into().unwrap();
    let offset = u64::from_be_bytes(head[16..24].try_into().unwrap());
    let want = proof(secret, b'R', task_id, &ns, &nr, offset);
    if !bool::from(want.ct_eq(&head[24..])) {
        return Ok(SendOutcome::Rejected); // not our peer
    }
    s.write_all(&proof(secret, b'S', task_id, &ns, &nr, offset))?;

    let mut f = File::open(file)?;
    let len = f.metadata()?.len();
    if offset > len {
        return Err(err("receiver offset beyond file"));
    }
    f.seek(SeekFrom::Start(offset))?;
    let mut ae = Aead_::derive(secret, &ns, &nr);
    let mut sent = offset;
    on_progress(sent);
    let mut buf = vec![0u8; CHUNK];
    while sent < len {
        let n = f.read(&mut buf)?;
        if n == 0 {
            return Err(err("file shrank"));
        }
        write_frame(&mut s, &ae.seal(T_DATA, &buf[..n]))?;
        sent += n as u64;
        on_progress(sent);
    }
    write_frame(&mut s, &ae.seal(T_END, &[]))?;
    s.flush()?;
    s.set_read_timeout(Some(Duration::from_secs(60)))?;
    let mut ack = [0u8; 1];
    s.read_exact(&mut ack)?;
    Ok(if ack[0] == 1 { SendOutcome::Ok } else { SendOutcome::Rejected })
}

/// An accepted task the receiver is willing to serve.
#[derive(Clone)]
pub struct Incoming {
    pub task_id: [u8; 16],
    pub secret: [u8; 32],
    pub size: u64,
    pub sha256_hex: String,
    pub part: PathBuf,
}

#[derive(Debug, PartialEq, Eq)]
pub enum RecvOutcome {
    /// Size and SHA-256 matched; the part file is complete (the caller renames it).
    Verified,
    /// Handshake passed but the content did not verify; the part file was removed.
    Corrupt,
}

/// Reads the sender's hello and returns the task id so the caller can look the task up.
pub fn read_hello(s: &mut TcpStream) -> io::Result<([u8; 16], [u8; 16])> {
    s.set_read_timeout(Some(Duration::from_secs(10)))?;
    let mut h = [0u8; 4 + 16 + 16];
    s.read_exact(&mut h)?;
    if &h[..4] != MAGIC {
        return Err(err("bad magic"));
    }
    Ok((h[4..20].try_into().unwrap(), h[20..].try_into().unwrap()))
}

/// Completes the handshake for `inc` and receives the file into `inc.part` (resuming a prefix).
pub fn receive(
    s: &mut TcpStream,
    inc: &Incoming,
    ns: [u8; 16],
    mut on_progress: impl FnMut(u64),
) -> io::Result<RecvOutcome> {
    s.set_nodelay(true)?;
    let mut have = std::fs::metadata(&inc.part).map(|m| m.len()).unwrap_or(0);
    if have > inc.size {
        let _ = std::fs::remove_file(&inc.part);
        have = 0;
    }
    let mut hasher = Sha256::new();
    if have > 0 {
        let mut f = File::open(&inc.part)?;
        let mut b = vec![0u8; 1 << 20];
        loop {
            let n = f.read(&mut b)?;
            if n == 0 {
                break;
            }
            hasher.update(&b[..n]);
        }
    }
    let mut nr = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut nr);
    s.write_all(&nr)?;
    s.write_all(&have.to_be_bytes())?;
    s.write_all(&proof(&inc.secret, b'R', &inc.task_id, &ns, &nr, have))?;
    let mut sp = [0u8; 32];
    s.read_exact(&mut sp)?;
    if !bool::from(sp.ct_eq(&proof(&inc.secret, b'S', &inc.task_id, &ns, &nr, have))) {
        return Err(err("peer failed authentication"));
    }
    s.set_read_timeout(Some(Duration::from_secs(30)))?;
    let mut ae = Aead_::derive(&inc.secret, &ns, &nr);
    let mut out = OpenOptions::new().create(true).append(have > 0).write(true).truncate(have == 0).open(&inc.part)?;
    let mut got = have;
    loop {
        let mut l = [0u8; 4];
        s.read_exact(&mut l)?;
        let len = u32::from_be_bytes(l) as usize;
        if len > MAX_FRAME {
            return Err(err("frame too large"));
        }
        let mut fr = vec![0u8; len];
        s.read_exact(&mut fr)?;
        let (ty, payload) = ae.open(&fr)?;
        if ty == T_END {
            break;
        }
        out.write_all(&payload)?;
        hasher.update(&payload);
        got += payload.len() as u64;
        if got > inc.size {
            return Err(err("too many bytes"));
        }
        on_progress(got);
    }
    out.flush()?;
    drop(out);
    let ok = got == inc.size && hex(&hasher.finalize()) == inc.sha256_hex;
    if !ok {
        let _ = std::fs::remove_file(&inc.part);
        s.write_all(&[0])?;
        return Ok(RecvOutcome::Corrupt);
    }
    s.write_all(&[1])?;
    Ok(RecvOutcome::Verified)
}

pub fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

pub fn unhex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok()).collect()
}

pub fn uuid_bytes(u: &str) -> Option<[u8; 16]> {
    unhex(&u.replace('-', ""))?.try_into().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::thread;

    fn sha(path: &Path) -> String {
        hex(&Sha256::digest(std::fs::read(path).unwrap()))
    }

    fn serve(l: TcpListener, inc: Incoming) -> thread::JoinHandle<io::Result<RecvOutcome>> {
        thread::spawn(move || {
            let (mut s, _) = l.accept()?;
            let (id, ns) = read_hello(&mut s)?;
            assert_eq!(id, inc.task_id);
            receive(&mut s, &inc, ns, |_| {})
        })
    }

    fn fixture(dir: &Path, size: usize) -> (PathBuf, Incoming) {
        let src = dir.join("src.bin");
        let data: Vec<u8> = (0..size).map(|i| (i * 31 % 251) as u8).collect();
        std::fs::write(&src, &data).unwrap();
        let inc = Incoming {
            task_id: [7; 16],
            secret: [9; 32],
            size: size as u64,
            sha256_hex: hex(&Sha256::digest(&data)),
            part: dir.join(".part"),
        };
        (src, inc)
    }

    #[test]
    fn roundtrip() {
        let d = tempfile::tempdir().unwrap();
        let (src, inc) = fixture(d.path(), 3 * 1024 * 1024 + 5);
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let h = serve(l, inc.clone());
        let r = send(("127.0.0.1", port), &inc.task_id, &inc.secret, &src, |_| {}).unwrap();
        assert_eq!(r, SendOutcome::Ok);
        assert_eq!(h.join().unwrap().unwrap(), RecvOutcome::Verified);
        assert_eq!(sha(&inc.part), inc.sha256_hex);
    }

    #[test]
    fn wrong_secret_is_rejected() {
        let d = tempfile::tempdir().unwrap();
        let (src, inc) = fixture(d.path(), 1000);
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let h = serve(l, inc.clone());
        let r = send(("127.0.0.1", port), &inc.task_id, &[1; 32], &src, |_| {}).unwrap();
        assert_eq!(r, SendOutcome::Rejected);
        assert!(h.join().unwrap().is_err());
        assert!(!inc.part.exists());
    }

    #[test]
    fn resumes_from_existing_prefix() {
        let d = tempfile::tempdir().unwrap();
        let (src, inc) = fixture(d.path(), 2 * 1024 * 1024);
        std::fs::write(&inc.part, &std::fs::read(&src).unwrap()[..700_000]).unwrap();
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let h = serve(l, inc.clone());
        let mut first = None;
        let r = send(("127.0.0.1", port), &inc.task_id, &inc.secret, &src, |b| {
            first.get_or_insert(b);
        })
        .unwrap();
        assert_eq!(r, SendOutcome::Ok);
        assert_eq!(first, Some(700_000));
        assert_eq!(h.join().unwrap().unwrap(), RecvOutcome::Verified);
        assert_eq!(sha(&inc.part), inc.sha256_hex);
    }

    #[test]
    fn corrupt_content_is_refused() {
        let d = tempfile::tempdir().unwrap();
        let (src, mut inc) = fixture(d.path(), 100_000);
        inc.sha256_hex = "0".repeat(64);
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let h = serve(l, inc.clone());
        let r = send(("127.0.0.1", port), &inc.task_id, &inc.secret, &src, |_| {}).unwrap();
        assert_eq!(r, SendOutcome::Rejected);
        assert_eq!(h.join().unwrap().unwrap(), RecvOutcome::Corrupt);
        assert!(!inc.part.exists());
    }
}
