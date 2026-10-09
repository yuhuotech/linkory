//! `linkory-lan`: tiny CLI around the LNK1 reference implementation (used for interoperability
//! tests against the Dart client and for manual diagnostics).
//!
//!   linkory-lan send --addr HOST:PORT --task UUID --secret HEX64 --file PATH
//!   linkory-lan recv --listen PORT --task UUID --secret HEX64 --size N --sha256 HEX64 --part PATH
//!
//! `recv` prints `PORT <n>` once listening, serves one session, prints `VERIFIED` or `CORRUPT`.
use std::net::TcpListener;
use std::path::PathBuf;
use std::process::exit;

use linkory_core::{read_hello, receive, send, unhex, uuid_bytes, Incoming, RecvOutcome, SendOutcome};

fn arg(args: &[String], k: &str) -> Option<String> {
    args.iter().position(|a| a == k).and_then(|i| args.get(i + 1)).cloned()
}

fn need(args: &[String], k: &str) -> String {
    arg(args, k).unwrap_or_else(|| {
        eprintln!("missing {k}");
        exit(2)
    })
}

fn secret(args: &[String]) -> [u8; 32] {
    unhex(&need(args, "--secret")).and_then(|v| v.try_into().ok()).unwrap_or_else(|| {
        eprintln!("--secret must be 64 hex chars");
        exit(2)
    })
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let id = || uuid_bytes(&need(&args, "--task")).unwrap_or_else(|| exit(2));
    match args.first().map(String::as_str) {
        Some("send") => {
            let r = send(need(&args, "--addr"), &id(), &secret(&args), &PathBuf::from(need(&args, "--file")), |_| {});
            match r {
                Ok(SendOutcome::Ok) => println!("OK"),
                Ok(SendOutcome::Rejected) => {
                    println!("REJECTED");
                    exit(3)
                }
                Err(e) => {
                    eprintln!("error: {e}");
                    exit(1)
                }
            }
        }
        Some("recv") => {
            let l = TcpListener::bind(("0.0.0.0", need(&args, "--listen").parse().unwrap_or(0))).expect("bind");
            println!("PORT {}", l.local_addr().unwrap().port());
            let inc = Incoming {
                task_id: id(),
                secret: secret(&args),
                size: need(&args, "--size").parse().expect("--size"),
                sha256_hex: need(&args, "--sha256"),
                part: PathBuf::from(need(&args, "--part")),
            };
            let (mut s, _) = l.accept().expect("accept");
            let res = read_hello(&mut s).and_then(|(tid, ns)| {
                if tid != inc.task_id {
                    return Err(std::io::Error::other("unknown task"));
                }
                receive(&mut s, &inc, ns, |_| {})
            });
            match res {
                Ok(RecvOutcome::Verified) => println!("VERIFIED"),
                Ok(RecvOutcome::Corrupt) => {
                    println!("CORRUPT");
                    exit(3)
                }
                Err(e) => {
                    eprintln!("error: {e}");
                    exit(1)
                }
            }
        }
        _ => {
            eprintln!("usage: linkory-lan send|recv ...");
            exit(2)
        }
    }
}
