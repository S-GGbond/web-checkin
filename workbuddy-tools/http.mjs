export function buildAuthHeaders(session, extra = {}) {
  const headers = {
    "Content-Type": "application/json",
    Accept: "application/json",
    ...extra,
  };
  if (session?.accessToken) headers.Authorization = `Bearer ${session.accessToken}`;
  if (session?.uid) headers["X-User-Id"] = session.uid;
  if (session?.enterpriseId) {
    headers["X-Enterprise-Id"] = session.enterpriseId;
    headers["X-Tenant-Id"] = session.enterpriseId;
  }
  if (session?.domain) headers["X-Domain"] = session.domain;
  return headers;
}

export async function requestJson(url, options = {}) {
  const response = await fetch(url, options);
  const text = await response.text();
  let body;
  try {
    body = text ? JSON.parse(text) : undefined;
  } catch {
    body = { raw: text };
  }
  return {
    ok: response.ok,
    status: response.status,
    body,
  };
}

export function checkinResultName(code) {
  switch (code) {
    case 0: return "claimed";
    case 1001: return "already_claimed";
    case 1002: return "not_eligible";
    case 1003: return "event_ended";
    default: return "unknown_biz_error";
  }
}
