Undertow Design Document
========================
Stuart Douglas <sdouglas@redhat.com>
v0.1, 2012

This is the design document for the undertow web server. It covers general
arcitecture and design considerations, it is not a requirements document.

Overview  
--------

The core Undertow architecture is based on the concept of lightweight async
handlers. These handlers are chained together to form a complete HTTP server.
The handlers can also hand off to blocking handlers backed by a thread pool.

This architecture is designed to give the end user complete flexibility when
configuring the server. For instance if the user simply wants to server up
static files, then they can confiure a server with only the handlers that are
required for that task. 

An example handler chain could be as follows:

![An Example Handler Chain](https://raw.github.com/stuartwdouglas/tmp/master/images/example.png "An Example Handler Chain")

Servlet functionality will be built on top of the async server core. The
servlet module will integrate with the core by providing its own handlers for
servlet specific functionality. As much as possible the servlet implementation
will use async handlers, only changing to blocking handlers when absolutly
required. This means that static resources packaged in a servlet will be
served up via async IO.


Core Server
===========

Incoming Requests
-----------------

Standard HTTP requests come into the server via the HTTPOpenListener, which
wraps the channel in a PushBackStreamChannel and  then hands off to the
HTTPReadListener. The HTTPReadListener parses the request as it comes in, and
once it has read all headers it creates a HTTPServerExchange and invokes the
root handler. Any of the content body / next request that is read by this
listener is pushed back onto the stream.

The HTTP parsing is done by a bytecode generated state machine, that
recognizes common headers and verbs. This means that parsing of common
headers can be done more quickly and with less memory usage, as if the header
value is known to the state machine an interned version of the string will be
returned directly, with no need to allocate a String or a StringBuilder. 

*NOTE:* It has not been shown yet if this will provide a significant
performance boost with a real workload. If not then we may want to move to a
simpler parser to avoid the extra complexity.

Other protocols such as HTTPS, AJP and SPDY etc support will be provided
through Channel implementation that as much as possible abstract away the
details of the underlying protocol to the handlers.

Handlers
--------

The basic handler interface is as follows:

	public interface HttpHandler {

	    /**
	     * Handle the request.
	     *
	     * @param exchange the HTTP request/response exchange
	     * @param completionHandler the completion handler
	     */
	    void handleRequest(HttpServerExchange exchange, HttpCompletionHandler completionHandler);
	}

The HttpServerExchange holds all current state to do with this request and the
response, including headers, response code, channels, etc. It can have
arbitrary attachments added to it, to allow handlers to attach objects to be
read by handlers later in the chain (for instance an Authentication handler
could attach the authenticated identity, which may then be used by a later
authorization handler to decide if the user should be able to access the
resource).

The HttpCompletionHandler is invoked when the request is completed. Any
handlers that require a cleanup action of some sort map wrap this instance
before passing it to the next handler. As these are asynchronous handlers the
call chain may return while the request is still running, so it is not
possible to cleanup in a finally block (in fact handlers should generally not
run any code after invoking the next handler).

Initially the handlers are invoked in the XNIO read thread. This means that
they must not perform any potentially blocking operations, as this will leave
the server unable to process other requests until the write thread returns.
Instead handlers should either use asynchronous operations that allow for
callbacks, or delegate the task to a thread pool (such as the XNIO worker
pool).

The request and response streams may be wrapped by a handler, by registering a
ChannelWrapper with the HttpServerExcahnge. This wrapping will generally only
be used by handlers that implement a transfer or a content encoding. For
instance to implement compression a handler would register a ChannelWrapper
that compresses any data that passes through it, and writes the compressed
data to the underlying channel. Note that these wrappers are only used to
write out the response body, they cannot be used to change the way the status
line and headers are written out.

Only a single hander can responsible for reading the request or writing the
body. If a handler attempts to get channel after another handler has already
grabbed it then null will be returned.

Persistent Connections
----------------------

Persistent connections are implemented by wrapping the request and response
channels with either a chunking or fixed length channel. Once the request has
been fully read the next request can be started immediately, with the next
response being provided with a gated stream that will not allow the response
to start until the current response is finished.

Session Handling
----------------

Sessions will be implemented with a SessionHandler. When a request is
processed this handler will check for an existing session cookie, if it is
found it will retrieve the session from the session manager, and attach it to
the HttpServerExchange. It will also attach the SessionManager to the
HttpServerExchange. Retrieving the session may require an asynchronous
operation (e.g. if the session is stored in a database, or located on another
node in the cluster).

Once the Session and SessionManager are attached to the exchange later handler
can sore data in the session, or use the session manager to create a new
session in one does not already exist.

Configuration
-------------

The core will not provide a configuration API as such, instead it is
programatically configured by assembling handler chains. XML configuration
will be provided by the AS7 subsystem. This allows the server to be used in an
embedded mode without any XML configuration. In order to provide a standalone
servlet container to compete with Tomcat and Jetty we will use a cut down AS7
instance, that just provides the web subsystem. This will mean that  users
will get all the AS7 benefits (modules, management etc) with a smaller
download and a container that is perceived as being more lightweight than a
full AS7 instance.

Error Handing
-------------

Error page generation is done by wrapping the HttpCompletionHandler. This
wrapper can then check if the response has already been committed, and if not
write out an error page. A completion handler that is later in the chain will
take precedence, as its completion wrapper will be invoked first.

Servlet
=======

Security
========
