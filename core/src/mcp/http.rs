/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

//! Minimal HTTP/1.1 listener for the MCP Streamable HTTP transport.
//!
//! Only `POST <token>/mcp` carries protocol traffic. The server never opens an
//! SSE stream, so `GET` answers 405 as the transport allows.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use super::protocol;
use super::tools::BudgetService;

const MAX_HEADER_BYTES: usize = 32 * 1024;
const MAX_BODY_BYTES: usize = 16 * 1024 * 1024;
const MAX_CONNECTIONS: usize = 32;
const IDLE_TIMEOUT: Duration = Duration::from_secs(30);
const ACCEPT_POLL_INTERVAL: Duration = Duration::from_millis(100);

pub(super) struct Request {
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Request {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

pub(super) struct Response {
    pub status: u16,
    pub content_type: Option<&'static str>,
    pub headers: Vec<(&'static str, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn empty(status: u16) -> Self {
        Self {
            status,
            content_type: None,
            headers: vec![],
            body: vec![],
        }
    }

    pub fn text(status: u16, message: &str) -> Self {
        Self {
            status,
            content_type: Some("text/plain; charset=utf-8"),
            headers: vec![],
            body: message.as_bytes().to_vec(),
        }
    }

    pub fn json(status: u16, value: &serde_json::Value) -> Self {
        Self {
            status,
            content_type: Some("application/json"),
            headers: vec![],
            body: serde_json::to_vec(value).unwrap_or_default(),
        }
    }
}

pub(super) fn spawn(
    listener: TcpListener,
    token: String,
    service: Arc<BudgetService>,
    shutdown: Arc<AtomicBool>,
) -> io::Result<JoinHandle<()>> {
    listener.set_nonblocking(true)?;
    let endpoint = format!("/{token}/mcp");
    thread::Builder::new()
        .name("bw-mcp-listener".to_string())
        .spawn(move || accept_loop(listener, endpoint, service, shutdown))
}

fn accept_loop(
    listener: TcpListener,
    endpoint: String,
    service: Arc<BudgetService>,
    shutdown: Arc<AtomicBool>,
) {
    let connections = Arc::new(AtomicUsize::new(0));
    while !shutdown.load(Ordering::SeqCst) {
        match listener.accept() {
            Ok((stream, _)) => {
                if connections.load(Ordering::SeqCst) >= MAX_CONNECTIONS {
                    let mut stream = stream;
                    let _ = stream.set_nonblocking(false);
                    let _ = write_response(&mut stream, Response::text(503, "Too many connections"), false);
                    continue;
                }
                connections.fetch_add(1, Ordering::SeqCst);
                let endpoint = endpoint.clone();
                let service = service.clone();
                let shutdown = shutdown.clone();
                let counter = connections.clone();
                let spawned = thread::Builder::new()
                    .name("bw-mcp-connection".to_string())
                    .spawn(move || {
                        let _ = serve_connection(stream, &endpoint, &service, &shutdown);
                        counter.fetch_sub(1, Ordering::SeqCst);
                    });
                if spawned.is_err() {
                    connections.fetch_sub(1, Ordering::SeqCst);
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(ACCEPT_POLL_INTERVAL);
            }
            Err(_) => thread::sleep(ACCEPT_POLL_INTERVAL),
        }
    }
}

fn serve_connection(
    stream: TcpStream,
    endpoint: &str,
    service: &BudgetService,
    shutdown: &AtomicBool,
) -> io::Result<()> {
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(IDLE_TIMEOUT))?;
    stream.set_write_timeout(Some(IDLE_TIMEOUT))?;
    let mut writer = stream.try_clone()?;
    let mut reader = BufReader::new(stream);

    loop {
        if shutdown.load(Ordering::SeqCst) {
            return Ok(());
        }
        let request = match read_request(&mut reader) {
            Ok(Some(request)) => request,
            Ok(None) => return Ok(()),
            Err(RequestError::Io(error)) => return Err(error),
            Err(RequestError::Bad(status, message)) => {
                write_response(&mut writer, Response::text(status, message), false)?;
                return Ok(());
            }
        };
        let keep_alive = !request
            .header("connection")
            .is_some_and(|value| value.eq_ignore_ascii_case("close"));
        let response = route(&request, endpoint, service);
        write_response(&mut writer, response, keep_alive)?;
        if !keep_alive {
            return Ok(());
        }
    }
}

fn route(request: &Request, endpoint: &str, service: &BudgetService) -> Response {
    let path = request.path.split('?').next().unwrap_or_default();
    let path = path.strip_suffix('/').unwrap_or(path);
    if !constant_time_eq(path.as_bytes(), endpoint.as_bytes()) {
        return Response::text(404, "Not found");
    }

    match request.method.as_str() {
        "POST" => protocol::handle_post(request, service),
        // No server-initiated SSE stream and no sessions to end.
        _ => {
            let mut response = Response::text(405, "Method not allowed");
            response.headers.push(("Allow", "POST".to_string()));
            response
        }
    }
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.iter()
        .zip(right)
        .fold(0_u8, |difference, (a, b)| difference | (a ^ b))
        == 0
}

enum RequestError {
    Io(io::Error),
    Bad(u16, &'static str),
}

impl From<io::Error> for RequestError {
    fn from(error: io::Error) -> Self {
        RequestError::Io(error)
    }
}

fn read_request(reader: &mut BufReader<TcpStream>) -> Result<Option<Request>, RequestError> {
    let mut header_bytes = 0;
    let mut request_line = String::new();
    loop {
        request_line.clear();
        let read = read_limited_line(reader, &mut request_line, &mut header_bytes)?;
        if read == 0 {
            return Ok(None);
        }
        // Tolerate blank lines between keep-alive requests.
        if !request_line.trim().is_empty() {
            break;
        }
    }

    let mut parts = request_line.split_whitespace();
    let (Some(method), Some(path), Some(version)) = (parts.next(), parts.next(), parts.next()) else {
        return Err(RequestError::Bad(400, "Malformed request line"));
    };
    if !version.starts_with("HTTP/1.") {
        return Err(RequestError::Bad(505, "HTTP version not supported"));
    }

    let mut headers = Vec::new();
    loop {
        let mut line = String::new();
        if read_limited_line(reader, &mut line, &mut header_bytes)? == 0 {
            return Err(RequestError::Bad(400, "Incomplete request headers"));
        }
        let line = line.trim_end_matches(['\r', '\n']);
        if line.is_empty() {
            break;
        }
        let (name, value) = line
            .split_once(':')
            .ok_or(RequestError::Bad(400, "Malformed header"))?;
        headers.push((name.trim().to_string(), value.trim().to_string()));
    }

    let mut request = Request {
        method: method.to_ascii_uppercase(),
        path: path.to_string(),
        headers,
        body: vec![],
    };

    if request
        .header("transfer-encoding")
        .is_some_and(|value| value.to_ascii_lowercase().contains("chunked"))
    {
        request.body = read_chunked_body(reader)?;
    } else if let Some(length) = request.header("content-length") {
        let length: usize = length
            .parse()
            .map_err(|_| RequestError::Bad(400, "Invalid Content-Length"))?;
        if length > MAX_BODY_BYTES {
            return Err(RequestError::Bad(413, "Request body too large"));
        }
        let mut body = vec![0; length];
        reader.read_exact(&mut body)?;
        request.body = body;
    }

    Ok(Some(request))
}

fn read_limited_line(
    reader: &mut BufReader<TcpStream>,
    line: &mut String,
    consumed: &mut usize,
) -> Result<usize, RequestError> {
    let mut bytes = Vec::new();
    let read = reader
        .by_ref()
        .take((MAX_HEADER_BYTES - *consumed + 1) as u64)
        .read_until(b'\n', &mut bytes)?;
    *consumed += read;
    if *consumed > MAX_HEADER_BYTES {
        return Err(RequestError::Bad(431, "Request headers too large"));
    }
    line.push_str(&String::from_utf8_lossy(&bytes));
    Ok(read)
}

fn read_chunked_body(reader: &mut BufReader<TcpStream>) -> Result<Vec<u8>, RequestError> {
    let mut body = Vec::new();
    loop {
        let mut size_line = String::new();
        let mut consumed = 0;
        read_limited_line(reader, &mut size_line, &mut consumed)?;
        let size_text = size_line.trim().split(';').next().unwrap_or_default();
        let size = usize::from_str_radix(size_text, 16)
            .map_err(|_| RequestError::Bad(400, "Invalid chunk size"))?;
        if size == 0 {
            // Skip optional trailers until the terminating blank line.
            loop {
                let mut trailer = String::new();
                if read_limited_line(reader, &mut trailer, &mut consumed)? == 0
                    || trailer.trim().is_empty()
                {
                    return Ok(body);
                }
            }
        }
        if body.len() + size > MAX_BODY_BYTES {
            return Err(RequestError::Bad(413, "Request body too large"));
        }
        let start = body.len();
        body.resize(start + size, 0);
        reader.read_exact(&mut body[start..])?;
        let mut crlf = [0_u8; 2];
        reader.read_exact(&mut crlf)?;
    }
}

fn reason_phrase(status: u16) -> &'static str {
    match status {
        200 => "OK",
        202 => "Accepted",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        411 => "Length Required",
        413 => "Payload Too Large",
        415 => "Unsupported Media Type",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        505 => "HTTP Version Not Supported",
        _ => "Unknown",
    }
}

fn write_response(stream: &mut TcpStream, response: Response, keep_alive: bool) -> io::Result<()> {
    let mut head = format!(
        "HTTP/1.1 {} {}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: {}\r\n",
        response.status,
        reason_phrase(response.status),
        response.body.len(),
        if keep_alive { "keep-alive" } else { "close" },
    );
    if let Some(content_type) = response.content_type {
        head.push_str(&format!("Content-Type: {content_type}\r\n"));
    }
    for (name, value) in &response.headers {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes())?;
    stream.write_all(&response.body)?;
    stream.flush()
}
