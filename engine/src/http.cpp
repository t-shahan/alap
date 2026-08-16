/// @file http.cpp
/// @brief libcurl-backed implementation of HttpClient.

#include "mailengine/http.hpp"

#include <curl/curl.h>

#include <utility>

namespace mailengine {
namespace {

/// libcurl write callback. Appends received bytes to a std::string.
///
/// The signature is fixed by libcurl: (ptr, size, nmemb, userdata). `size` is
/// always 1 in practice, but multiplying is the documented contract. Returning
/// anything other than the full byte count signals an error to curl and aborts
/// the transfer.
size_t append_to_string(char* ptr, size_t size, size_t nmemb, void* userdata) {
  auto* out = static_cast<std::string*>(userdata);
  const size_t bytes = size * nmemb;
  out->append(ptr, bytes);
  return bytes;
}

/// RAII owner for curl's linked-list header type.
///
/// curl_slist_append allocates, and the list must outlive the transfer but be
/// freed after it. A guard type removes every early-return leak.
class HeaderList {
 public:
  void add(const std::string& header) {
    list_ = curl_slist_append(list_, header.c_str());
  }
  ~HeaderList() {
    if (list_ != nullptr) {
      curl_slist_free_all(list_);
    }
  }
  HeaderList() = default;
  HeaderList(const HeaderList&) = delete;
  HeaderList& operator=(const HeaderList&) = delete;

  [[nodiscard]] curl_slist* get() const noexcept { return list_; }

 private:
  curl_slist* list_ = nullptr;
};

}  // namespace

HttpClient::HttpClient() {
  handle_ = curl_easy_init();
}

HttpClient::~HttpClient() {
  if (handle_ != nullptr) {
    curl_easy_cleanup(static_cast<CURL*>(handle_));
  }
}

HttpClient::HttpClient(HttpClient&& other) noexcept
    : handle_(std::exchange(other.handle_, nullptr)),
      timeout_seconds_(other.timeout_seconds_) {}

HttpClient& HttpClient::operator=(HttpClient&& other) noexcept {
  if (this != &other) {
    if (handle_ != nullptr) {
      curl_easy_cleanup(static_cast<CURL*>(handle_));
    }
    handle_ = std::exchange(other.handle_, nullptr);
    timeout_seconds_ = other.timeout_seconds_;
  }
  return *this;
}

Result<HttpResponse> HttpClient::perform(
    const std::string& url,
    const std::map<std::string, std::string>& headers) {
  auto* curl = static_cast<CURL*>(handle_);
  if (curl == nullptr) {
    return make_error("curl handle not initialised");
  }

  std::string body;
  HeaderList header_list;
  for (const auto& [name, value] : headers) {
    header_list.add(name + ": " + value);
  }

  curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, append_to_string);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &body);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout_seconds_);
  curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
  // Certificate verification stays on. Google's endpoints hold real certs and
  // there is never a reason to disable this.
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
  curl_easy_setopt(curl, CURLOPT_USERAGENT, "mailengine/0.1");
  if (header_list.get() != nullptr) {
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, header_list.get());
  }

  const CURLcode code = curl_easy_perform(curl);
  if (code != CURLE_OK) {
    return make_error(curl_easy_strerror(code), static_cast<int>(code));
  }

  long status = 0;
  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);

  // Reset per-request state so the next call on this handle starts clean while
  // keeping the connection pool and TLS session.
  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, nullptr);
  curl_easy_setopt(curl, CURLOPT_POST, 0L);

  return HttpResponse{status, std::move(body)};
}

Result<HttpResponse> HttpClient::get(
    const std::string& url,
    const std::map<std::string, std::string>& headers) {
  auto* curl = static_cast<CURL*>(handle_);
  if (curl == nullptr) {
    return make_error("curl handle not initialised");
  }
  curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
  return perform(url, headers);
}

Result<HttpResponse> HttpClient::post(
    const std::string& url,
    const std::string& body,
    const std::string& content_type,
    const std::map<std::string, std::string>& headers) {
  auto* curl = static_cast<CURL*>(handle_);
  if (curl == nullptr) {
    return make_error("curl handle not initialised");
  }

  auto with_type = headers;
  with_type["Content-Type"] = content_type;

  curl_easy_setopt(curl, CURLOPT_POST, 1L);
  // COPYPOSTFIELDS copies the buffer, so `body` need not outlive the call.
  curl_easy_setopt(curl, CURLOPT_COPYPOSTFIELDS, body.c_str());
  curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(body.size()));

  return perform(url, with_type);
}

std::string HttpClient::url_encode(const std::string& value) {
  // curl_easy_escape needs a handle but does not perform I/O; a throwaway is
  // fine and avoids requiring an HttpClient instance for a pure function.
  CURL* curl = curl_easy_init();
  if (curl == nullptr) {
    return value;
  }
  char* escaped = curl_easy_escape(curl, value.c_str(), static_cast<int>(value.size()));
  std::string result = (escaped != nullptr) ? escaped : value;
  if (escaped != nullptr) {
    curl_free(escaped);
  }
  curl_easy_cleanup(curl);
  return result;
}

std::string HttpClient::form_encode(
    const std::vector<std::pair<std::string, std::string>>& fields) {
  std::string out;
  for (const auto& [key, value] : fields) {
    if (!out.empty()) {
      out += '&';
    }
    out += url_encode(key);
    out += '=';
    out += url_encode(value);
  }
  return out;
}

}  // namespace mailengine
