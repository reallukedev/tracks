//! The request and response the host sends and receives with its own HTTP stack.

/// An HTTP method.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Method {
    /// `GET`.
    Get,
    /// `POST`.
    Post,
}

impl Method {
    /// The method's name as it goes on the wire.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Get => "GET",
            Self::Post => "POST",
        }
    }
}

/// A request for the host to send as is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpRequest {
    /// The method.
    pub method: Method,
    /// The full URL.
    pub url: String,
    /// Header names and values, in order.
    pub headers: Vec<(String, String)>,
    /// The body, empty for none.
    pub body: Vec<u8>,
}

impl HttpRequest {
    /// The value of the first header with this name, ignoring case.
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

/// What the host got back. A transport failure never becomes one of these: the host reports
/// it in its own terms.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpResponse {
    /// The HTTP status code.
    pub status: u16,
    /// The raw body.
    pub body: Vec<u8>,
}

impl HttpResponse {
    /// A response with this status and body.
    pub fn new(status: u16, body: impl Into<Vec<u8>>) -> Self {
        Self {
            status,
            body: body.into(),
        }
    }
}
