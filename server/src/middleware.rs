use axum::{
    body::Body,
    http::{
        Request,
        header::{CACHE_CONTROL, HeaderValue},
    },
    middleware::Next,
    response::Response,
};
use tracing::Instrument;
use uuid::Uuid;

use crate::errors::RequestContext;

pub async fn request_context(mut request: Request<Body>, next: Next) -> Response {
    let context = RequestContext { id: Uuid::new_v4() };
    let method = request.method().clone();
    let path = request.uri().path().to_owned();
    request.extensions_mut().insert(context);

    let span = tracing::info_span!(
        "http_request",
        request_id = %context.id,
        method = %method,
        path = %path,
    );
    let mut response = next.run(request).instrument(span).await;
    response.headers_mut().insert(
        "x-request-id",
        HeaderValue::from_str(&context.id.to_string()).expect("UUID is a valid header value"),
    );
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    tracing::info!(status = response.status().as_u16(), "request completed");
    response
}
