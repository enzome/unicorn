/**
 * Copyright (c) 2009 Eric Wong (all bugs are Eric's fault)
 * Copyright (c) 2005 Zed A. Shaw
 * You can redistribute it and/or modify it under the same terms as Ruby.
 */
#include "ruby.h"
#include "ext_help.h"
#include <assert.h>
#include <string.h>
#include <sys/types.h>
#include "common_field_optimization.h"
#include "global_variables.h"
#include "c_util.h"

#define UH_FL_CHUNKED  0x1
#define UH_FL_HASBODY  0x2
#define UH_FL_INBODY   0x4
#define UH_FL_HASTRAILER 0x8
#define UH_FL_INTRAILER 0x10
#define UH_FL_INCHUNK  0x20
#define UH_FL_KAMETHOD 0x40
#define UH_FL_KAVERSION 0x80
#define UH_FL_HASHEADER 0x100

#define UH_FL_KEEPALIVE (UH_FL_KAMETHOD | UH_FL_KAVERSION)

struct http_parser {
  int cs; /* Ragel internal state */
  unsigned int flags;
  size_t mark;
  union { /* these 3 fields don't nest */
    size_t field;
    size_t query;
    size_t offset;
  } start;
  union {
    size_t field_len; /* only used during header processing */
    size_t dest_offset; /* only used during body processing */
  } s;
  VALUE cont;
  union {
    off_t content;
    off_t chunk;
  } len;
};

static void finalize_header(struct http_parser *hp, VALUE req);

#define REMAINING (unsigned long)(pe - p)
#define LEN(AT, FPC) (FPC - buffer - hp->AT)
#define MARK(M,FPC) (hp->M = (FPC) - buffer)
#define PTR_TO(F) (buffer + hp->F)
#define STR_NEW(M,FPC) rb_str_new(PTR_TO(M), LEN(M, FPC))

static void
request_method(struct http_parser *hp, VALUE req, const char *ptr, size_t len)
{
  VALUE v;

  if (CONST_MEM_EQ("GET", ptr, len)) {
    hp->flags |= UH_FL_KAMETHOD;
    v = g_GET;
  } else if (CONST_MEM_EQ("HEAD", ptr, len)) {
    hp->flags |= UH_FL_KAMETHOD;
    v = g_HEAD;
  } else {
    v = rb_str_new(ptr, len);
  }
  rb_hash_aset(req, g_request_method, v);
}

static void
http_version(struct http_parser *hp, VALUE req, const char *ptr, size_t len)
{
  VALUE v;

  hp->flags |= UH_FL_HASHEADER;

  if (CONST_MEM_EQ("HTTP/1.1", ptr, len)) {
    hp->flags |= UH_FL_KAVERSION;
    v = g_http_11;
  } else if (CONST_MEM_EQ("HTTP/1.0", ptr, len)) {
    v = g_http_10;
  } else {
    v = rb_str_new(ptr, len);
  }
  rb_hash_aset(req, g_server_protocol, v);
  rb_hash_aset(req, g_http_version, v);
}

static inline void hp_invalid_if_trailer(struct http_parser *hp)
{
  if (hp->flags & UH_FL_INTRAILER)
    rb_raise(eHttpParserError, "invalid Trailer");
}

static void write_cont_value(struct http_parser *hp,
                             const char *buffer, const char *p)
{
  char *vptr;

  if (!hp->cont)
    rb_raise(eHttpParserError, "invalid continuation line");

  assert(hp->mark > 0);

  if (LEN(mark, p) == 0)
    return;

  if (RSTRING_LEN(hp->cont) > 0)
    --hp->mark;

  vptr = (char *)PTR_TO(mark);

  if (RSTRING_LEN(hp->cont) > 0) {
    assert(' ' == *vptr || '\t' == *vptr);
    *vptr = ' ';
  }
  rb_str_buf_cat(hp->cont, vptr, LEN(mark, p));
}

static void write_value(VALUE req, struct http_parser *hp,
                        const char *buffer, const char *p)
{
  VALUE f = find_common_field(PTR_TO(start.field), hp->s.field_len);
  VALUE v;
  VALUE e;

  VALIDATE_MAX_LENGTH(LEN(mark, p), FIELD_VALUE);
  v = STR_NEW(mark, p);
  if (f == Qnil) {
    VALIDATE_MAX_LENGTH(hp->s.field_len, FIELD_NAME);
    f = uncommon_field(PTR_TO(start.field), hp->s.field_len);
  } else if (f == g_http_connection) {
    if (hp->flags & UH_FL_KAMETHOD) {
      if (STR_CSTR_CASE_EQ(v, "keep-alive"))
        hp->flags |= UH_FL_KAVERSION;
      else if (STR_CSTR_CASE_EQ(v, "close"))
        hp->flags &= ~UH_FL_KEEPALIVE;
    }
  } else if (f == g_content_length) {
    hp->len.content = parse_length(RSTRING_PTR(v), RSTRING_LEN(v));
    if (hp->len.content < 0)
      rb_raise(eHttpParserError, "invalid Content-Length");
    hp->flags |= UH_FL_HASBODY;
    hp_invalid_if_trailer(hp);
  } else if (f == g_http_transfer_encoding) {
    if (STR_CSTR_CASE_EQ(v, "chunked"))
      hp->flags |= UH_FL_CHUNKED | UH_FL_HASBODY;
    hp_invalid_if_trailer(hp);
  } else if (f == g_http_trailer) {
    hp->flags |= UH_FL_HASTRAILER;
    hp_invalid_if_trailer(hp);
  }

  e = rb_hash_aref(req, f);
  if (e == Qnil) {
    hp->cont = rb_hash_aset(req, f, v);
  } else if (f == g_http_host) {
    /*
     * ignored, absolute URLs in REQUEST_URI take precedence over
     * the Host: header (ref: rfc 2616, section 5.2.1)
     */
  } else {
    rb_str_buf_cat(e, ",", 1);
    hp->cont = rb_str_buf_append(e, v);
  }
}

/** Machine **/

%%{
  machine http_parser;

  action mark {MARK(mark, fpc); }

  action start_field { MARK(start.field, fpc); }
  action snake_upcase_field { snake_upcase_char((char *)fpc); }
  action downcase_char { downcase_char((char *)fpc); }
  action write_field { hp->s.field_len = LEN(start.field, fpc); }
  action start_value { MARK(mark, fpc); }
  action write_value { write_value(req, hp, buffer, fpc); }
  action write_cont_value { write_cont_value(hp, buffer, fpc); }
  action request_method {
    request_method(hp, req, PTR_TO(mark), LEN(mark, fpc));
  }
  action scheme {
    rb_hash_aset(req, g_rack_url_scheme, STR_NEW(mark, fpc));
  }
  action host {
    rb_hash_aset(req, g_http_host, STR_NEW(mark, fpc));
  }
  action request_uri {
    size_t len = LEN(mark, fpc);
    VALUE str;

    VALIDATE_MAX_LENGTH(len, REQUEST_URI);
    str = rb_hash_aset(req, g_request_uri, STR_NEW(mark, fpc));
    /*
     * "OPTIONS * HTTP/1.1\r\n" is a valid request, but we can't have '*'
     * in REQUEST_PATH or PATH_INFO or else Rack::Lint will complain
     */
    if (STR_CSTR_EQ(str, "*")) {
      str = rb_str_new(NULL, 0);
      rb_hash_aset(req, g_path_info, str);
      rb_hash_aset(req, g_request_path, str);
    }
  }
  action fragment {
    VALIDATE_MAX_LENGTH(LEN(mark, fpc), FRAGMENT);
    rb_hash_aset(req, g_fragment, STR_NEW(mark, fpc));
  }
  action start_query {MARK(start.query, fpc); }
  action query_string {
    VALIDATE_MAX_LENGTH(LEN(start.query, fpc), QUERY_STRING);
    rb_hash_aset(req, g_query_string, STR_NEW(start.query, fpc));
  }
  action http_version { http_version(hp, req, PTR_TO(mark), LEN(mark, fpc)); }
  action request_path {
    VALUE val;
    size_t len = LEN(mark, fpc);

    VALIDATE_MAX_LENGTH(len, REQUEST_PATH);
    val = rb_hash_aset(req, g_request_path, STR_NEW(mark, fpc));

    /* rack says PATH_INFO must start with "/" or be empty */
    if (!STR_CSTR_EQ(val, "*"))
      rb_hash_aset(req, g_path_info, val);
  }
  action add_to_chunk_size {
    hp->len.chunk = step_incr(hp->len.chunk, fc, 16);
    if (hp->len.chunk < 0)
      rb_raise(eHttpParserError, "invalid chunk size");
  }
  action header_done {
    finalize_header(hp, req);

    cs = http_parser_first_final;
    if (hp->flags & UH_FL_HASBODY) {
      hp->flags |= UH_FL_INBODY;
      if (hp->flags & UH_FL_CHUNKED)
        cs = http_parser_en_ChunkedBody;
    } else {
      assert(!(hp->flags & UH_FL_CHUNKED));
    }
    /*
     * go back to Ruby so we can call the Rack application, we'll reenter
     * the parser iff the body needs to be processed.
     */
    goto post_exec;
  }

  action end_trailers {
    cs = http_parser_first_final;
    goto post_exec;
  }

  action end_chunked_body {
    if (hp->flags & UH_FL_HASTRAILER) {
      hp->flags |= UH_FL_INTRAILER;
      cs = http_parser_en_Trailers;
    } else {
      cs = http_parser_first_final;
    }
    ++p;
    goto post_exec;
  }

  action skip_chunk_data {
  skip_chunk_data_hack: {
    size_t nr = MIN(hp->len.chunk, REMAINING);
    memcpy(RSTRING_PTR(req) + hp->s.dest_offset, fpc, nr);
    hp->s.dest_offset += nr;
    hp->len.chunk -= nr;
    p += nr;
    assert(hp->len.chunk >= 0);
    if (hp->len.chunk > REMAINING) {
      hp->flags |= UH_FL_INCHUNK;
      goto post_exec;
    } else {
      fhold;
      fgoto chunk_end;
    }
  }}

  include unicorn_http_common "unicorn_http_common.rl";
}%%

/** Data **/
%% write data;

static void http_parser_init(struct http_parser *hp)
{
  int cs = 0;
  memset(hp, 0, sizeof(struct http_parser));
  %% write init;
  hp->cs = cs;
}

/** exec **/
static void http_parser_execute(struct http_parser *hp,
  VALUE req, const char *buffer, size_t len)
{
  const char *p, *pe;
  int cs = hp->cs;
  size_t off = hp->start.offset;

  if (cs == http_parser_first_final)
    return;

  assert(off <= len && "offset past end of buffer");

  p = buffer+off;
  pe = buffer+len;

  assert(pe - p == len - off && "pointers aren't same distance");

  if (hp->flags & UH_FL_INCHUNK) {
    hp->flags &= ~(UH_FL_INCHUNK);
    goto skip_chunk_data_hack;
  }
  %% write exec;
post_exec: /* "_out:" also goes here */
  if (hp->cs != http_parser_error)
    hp->cs = cs;
  hp->start.offset = p - buffer;

  assert(p <= pe && "buffer overflow after parsing execute");
  assert(hp->start.offset <= len && "start.offset longer than length");
}

static struct http_parser *data_get(VALUE self)
{
  struct http_parser *hp;

  Data_Get_Struct(self, struct http_parser, hp);
  assert(hp);
  return hp;
}

static void finalize_header(struct http_parser *hp, VALUE req)
{
  VALUE temp = rb_hash_aref(req, g_rack_url_scheme);
  VALUE server_name = g_localhost;
  VALUE server_port = g_port_80;

  /* set rack.url_scheme to "https" or "http", no others are allowed by Rack */
  if (temp == Qnil) {
    temp = rb_hash_aref(req, g_http_x_forwarded_proto);
    if (temp != Qnil && STR_CSTR_EQ(temp, "https"))
      server_port = g_port_443;
    else
      temp = g_http;
    rb_hash_aset(req, g_rack_url_scheme, temp);
  } else if (STR_CSTR_EQ(temp, "https")) {
    server_port = g_port_443;
  }

  /* parse and set the SERVER_NAME and SERVER_PORT variables */
  temp = rb_hash_aref(req, g_http_host);
  if (temp != Qnil) {
    char *colon = memchr(RSTRING_PTR(temp), ':', RSTRING_LEN(temp));
    if (colon) {
      long port_start = colon - RSTRING_PTR(temp) + 1;

      server_name = rb_str_substr(temp, 0, colon - RSTRING_PTR(temp));
      if ((RSTRING_LEN(temp) - port_start) > 0)
        server_port = rb_str_substr(temp, port_start, RSTRING_LEN(temp));
    } else {
      server_name = temp;
    }
  }
  rb_hash_aset(req, g_server_name, server_name);
  rb_hash_aset(req, g_server_port, server_port);
  if (!(hp->flags & UH_FL_HASHEADER))
    rb_hash_aset(req, g_server_protocol, g_http_09);

  /* rack requires QUERY_STRING */
  if (rb_hash_aref(req, g_query_string) == Qnil)
    rb_hash_aset(req, g_query_string, rb_str_new(NULL, 0));
}

static void hp_mark(void *ptr)
{
  struct http_parser *hp = ptr;

  if (hp->cont)
    rb_gc_mark(hp->cont);
}

static VALUE HttpParser_alloc(VALUE klass)
{
  struct http_parser *hp;
  return Data_Make_Struct(klass, struct http_parser, hp_mark, NULL, hp);
}


/**
 * call-seq:
 *    parser.new => parser
 *
 * Creates a new parser.
 */
static VALUE HttpParser_init(VALUE self)
{
  http_parser_init(data_get(self));

  return self;
}

/**
 * call-seq:
 *    parser.reset => nil
 *
 * Resets the parser to it's initial state so that you can reuse it
 * rather than making new ones.
 */
static VALUE HttpParser_reset(VALUE self)
{
  http_parser_init(data_get(self));

  return Qnil;
}

static void advance_str(VALUE str, off_t nr)
{
  long len = RSTRING_LEN(str);

  if (len == 0)
    return;

  rb_str_modify(str);

  assert(nr <= len);
  len -= nr;
  if (len > 0) /* unlikely, len is usually 0 */
    memmove(RSTRING_PTR(str), RSTRING_PTR(str) + nr, len);
  rb_str_set_len(str, len);
}

/**
 * call-seq:
 *   parser.content_length => nil or Integer
 *
 * Returns the number of bytes left to run through HttpParser#filter_body.
 * This will initially be the value of the "Content-Length" HTTP header
 * after header parsing is complete and will decrease in value as
 * HttpParser#filter_body is called for each chunk.  This should return
 * zero for requests with no body.
 *
 * This will return nil on "Transfer-Encoding: chunked" requests.
 */
static VALUE HttpParser_content_length(VALUE self)
{
  struct http_parser *hp = data_get(self);

  return (hp->flags & UH_FL_CHUNKED) ? Qnil : OFFT2NUM(hp->len.content);
}

/**
 * Document-method: trailers
 * call-seq:
 *    parser.trailers(req, data) => req or nil
 *
 * This is an alias for HttpParser#headers
 */

/**
 * Document-method: headers
 * call-seq:
 *    parser.headers(req, data) => req or nil
 *
 * Takes a Hash and a String of data, parses the String of data filling
 * in the Hash returning the Hash if parsing is finished, nil otherwise
 * When returning the req Hash, it may modify data to point to where
 * body processing should begin.
 *
 * Raises HttpParserError if there are parsing errors.
 */
static VALUE HttpParser_headers(VALUE self, VALUE req, VALUE data)
{
  struct http_parser *hp = data_get(self);

  http_parser_execute(hp, req, RSTRING_PTR(data), RSTRING_LEN(data));
  VALIDATE_MAX_LENGTH(hp->start.offset, HEADER);

  if (hp->cs == http_parser_first_final ||
      hp->cs == http_parser_en_ChunkedBody) {
    advance_str(data, hp->start.offset + 1);
    hp->start.offset = 0;

    return req;
  }

  if (hp->cs == http_parser_error)
    rb_raise(eHttpParserError, "Invalid HTTP format, parsing fails.");

  return Qnil;
}

static int chunked_eof(struct http_parser *hp)
{
  return ((hp->cs == http_parser_first_final) ||
          (hp->flags & UH_FL_INTRAILER));
}

/**
 * call-seq:
 *    parser.body_eof? => true or false
 *
 * Detects if we're done filtering the body or not.  This can be used
 * to detect when to stop calling HttpParser#filter_body.
 */
static VALUE HttpParser_body_eof(VALUE self)
{
  struct http_parser *hp = data_get(self);

  if (hp->flags & UH_FL_CHUNKED)
    return chunked_eof(hp) ? Qtrue : Qfalse;

  return hp->len.content == 0 ? Qtrue : Qfalse;
}

/**
 * call-seq:
 *    parser.keepalive? => true or false
 *
 * This should be used to detect if a request can really handle
 * keepalives and pipelining.  Currently, the rules are:
 *
 * 1. MUST be a GET or HEAD request
 * 2. MUST be HTTP/1.1 +or+ HTTP/1.0 with "Connection: keep-alive"
 * 3. MUST NOT have "Connection: close" set
 */
static VALUE HttpParser_keepalive(VALUE self)
{
  struct http_parser *hp = data_get(self);

  return (hp->flags & UH_FL_KEEPALIVE) == UH_FL_KEEPALIVE ? Qtrue : Qfalse;
}

/**
 * call-seq:
 *    parser.headers? => true or false
 *
 * This should be used to detect if a request has headers (and if
 * the response will have headers as well).  HTTP/0.9 requests
 * should return false, all subsequent HTTP versions will return true
 */
static VALUE HttpParser_has_headers(VALUE self)
{
  struct http_parser *hp = data_get(self);

  return (hp->flags & UH_FL_HASHEADER) ? Qtrue : Qfalse;
}

/**
 * call-seq:
 *    parser.filter_body(buf, data) => nil/data
 *
 * Takes a String of +data+, will modify data if dechunking is done.
 * Returns +nil+ if there is more data left to process.  Returns
 * +data+ if body processing is complete. When returning +data+,
 * it may modify +data+ so the start of the string points to where
 * the body ended so that trailer processing can begin.
 *
 * Raises HttpParserError if there are dechunking errors.
 * Basically this is a glorified memcpy(3) that copies +data+
 * into +buf+ while filtering it through the dechunker.
 */
static VALUE HttpParser_filter_body(VALUE self, VALUE buf, VALUE data)
{
  struct http_parser *hp = data_get(self);
  char *dptr = RSTRING_PTR(data);
  long dlen = RSTRING_LEN(data);

  StringValue(buf);
  rb_str_resize(buf, dlen); /* we can never copy more than dlen bytes */
  OBJ_TAINT(buf); /* keep weirdo $SAFE users happy */

  if (hp->flags & UH_FL_CHUNKED) {
    if (chunked_eof(hp))
      goto end_of_body;

    hp->s.dest_offset = 0;
    http_parser_execute(hp, buf, dptr, dlen);
    if (hp->cs == http_parser_error)
      rb_raise(eHttpParserError, "Invalid HTTP format, parsing fails.");

    assert(hp->s.dest_offset <= hp->start.offset);
    advance_str(data, hp->start.offset);
    rb_str_set_len(buf, hp->s.dest_offset);

    if (RSTRING_LEN(buf) == 0 && chunked_eof(hp)) {
      assert(hp->len.chunk == 0);
    } else {
      data = Qnil;
    }
  } else {
    /* no need to enter the Ragel machine for unchunked transfers */
    assert(hp->len.content >= 0);
    if (hp->len.content > 0) {
      long nr = MIN(dlen, hp->len.content);

      memcpy(RSTRING_PTR(buf), dptr, nr);
      hp->len.content -= nr;
      if (hp->len.content == 0)
        hp->cs = http_parser_first_final;
      advance_str(data, nr);
      rb_str_set_len(buf, nr);
      data = Qnil;
    }
  }
end_of_body:
  hp->start.offset = 0; /* for trailer parsing */
  return data;
}

#define SET_GLOBAL(var,str) do { \
  var = find_common_field(str, sizeof(str) - 1); \
  assert(var != Qnil); \
} while (0)

void Init_unicorn_http(void)
{
  mUnicorn = rb_define_module("Unicorn");
  eHttpParserError =
         rb_define_class_under(mUnicorn, "HttpParserError", rb_eIOError);
  cHttpParser = rb_define_class_under(mUnicorn, "HttpParser", rb_cObject);
  init_globals();
  rb_define_alloc_func(cHttpParser, HttpParser_alloc);
  rb_define_method(cHttpParser, "initialize", HttpParser_init,0);
  rb_define_method(cHttpParser, "reset", HttpParser_reset,0);
  rb_define_method(cHttpParser, "headers", HttpParser_headers, 2);
  rb_define_method(cHttpParser, "filter_body", HttpParser_filter_body, 2);
  rb_define_method(cHttpParser, "trailers", HttpParser_headers, 2);
  rb_define_method(cHttpParser, "content_length", HttpParser_content_length, 0);
  rb_define_method(cHttpParser, "body_eof?", HttpParser_body_eof, 0);
  rb_define_method(cHttpParser, "keepalive?", HttpParser_keepalive, 0);
  rb_define_method(cHttpParser, "headers?", HttpParser_has_headers, 0);

  /*
   * The maximum size a single chunk when using chunked transfer encoding.
   * This is only a theoretical maximum used to detect errors in clients,
   * it is highly unlikely to encounter clients that send more than
   * several kilobytes at once.
   */
  rb_define_const(cHttpParser, "CHUNK_MAX", OFFT2NUM(UH_OFF_T_MAX));

  /*
   * The maximum size of the body as specified by Content-Length.
   * This is only a theoretical maximum, the actual limit is subject
   * to the limits of the file system used for +Dir.tmpdir+.
   */
  rb_define_const(cHttpParser, "LENGTH_MAX", OFFT2NUM(UH_OFF_T_MAX));

  init_common_fields();
  SET_GLOBAL(g_http_host, "HOST");
  SET_GLOBAL(g_http_trailer, "TRAILER");
  SET_GLOBAL(g_http_transfer_encoding, "TRANSFER_ENCODING");
  SET_GLOBAL(g_content_length, "CONTENT_LENGTH");
  SET_GLOBAL(g_http_connection, "CONNECTION");
}
#undef SET_GLOBAL
