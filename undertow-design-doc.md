Undertow Design Document
========================
Stuart Douglas <sdouglas@redhat.com>
v0.1, 2012

This is the design document for the undertow web server. It covers general
architecture and design considerations, it is not a requirements document.

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
wraps the channel in a PushBackStreamChannel and then hands off to the
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
ChannelWrapper with the HttpServerExchange. This wrapping will generally only
be used by handlers that implement a transfer or a content encoding. For
instance to implement compression a handler would register a ChannelWrapper
that compresses any data that passes through it, and writes the compressed
data to the underlying channel. Note that these wrappers are only used to
write out the response body, they cannot be used to change the way the status
line and headers are written out.

Only a single handler can responsible for reading the request or writing the
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
can store data in the session, or use the session manager to create a new
session if one does not already exist.

Configuration
-------------

The core will not provide a configuration API as such, instead it is
programatically configured by assembling handler chains. XML configuration
will be provided by the AS7 subsystem. This allows the server to be used in an
embedded mode without any XML configuration. In order to provide a standalone
servlet container to compete with Tomcat and Jetty we will use a cut down AS7
instance, that just provides the web subsystem. This will mean that users
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

Undertow Servlet Core
---------------------

The core servlet code will reside in the undertow respository, with the 
EE integration code residing in the AS7. Core servlet code is loosly defined
as the following functionality:

- Lifecycle management
- Core servlet handlers, including all request handling functionality
- Session management


AS7 Is responsible for the following:

- XML parsing and annotation processing
- Instance injection, creation and destruction
- Clustering

TODO: Fully define exactly what goes where.

The servlet component of Undertow will be configurable by a fluent API, that
AS7 and other integrators will use. This API takes the place of XML and
annotation parsing, the container will use this API to build up a deployment
and control its lifecycle.

Servlet Handler Chain
---------------------

The handler chain responsible for servlet invocations will generally be very
short, with most functionality being provided by non-blocking handlers layered
in front of the servlet handlers. Servlet core will provide the following
handlers:

- A handler that dispatches the request to the appropriate handler chain, 
taking into account all the servlet and filter path matching rules. 
- A handler that creates the spec required request/response wrapper objects
and attaches them to the exchange.
- A handler that invokes the filters
- A handler that invokes the servlet

As much functionality as possible will be handled by non-blocking handlers. For
instance if a request path is not routed though any filters or servlets, then
it will not be routed through any blocking handlers, and any static resources
will instead be served via an async handler.

Configuration and Bootstrap
---------------------------

The basic configuration will be done via a fluent builder API, an example of
what this might look like is shown below:

	final PathHandler root = new PathHandler();
        final ServletContainer container = new ServletContainer(root);

        ServletInfo.ServletInfoBuilder s = ServletInfo.builder()
                .setName("servlet")
                .setServletClass(SimpleServlet.class)
                .addMapping("/aa");

        DeploymentInfo.DeploymentInfoBuilder builder = DeploymentInfo.builder()
                .setClassLoader(SimpleServletServerTestCase.class.getClassLoader())
                .setContextName("/servletContext")
                .setDeploymentName("servletContext.war")
                .setResourceLoader(TestResourceLoader.INSTANCE)
                .addServlet(s);

        DeploymentManager manager = container.addDeployment(builder);
        manager.deploy();
        manager.start();


A deep copy of these builders may be further modified during the deploy()
phase by ServletContainerInitializers (It is necessary to clone the builders
so we always retain the original configuration if the MSC service is bounced).

Once the deploy() phase is finished builders build an immutable copy of the
DeploymentInfo, that contains all the deployments configuration. When start()
is called this metadata is used to construct the appropriate handler chains. 


JBoss Application Server Integration
------------------------------------

Initially this integration will be provided by a seperate module maintained in
the Undertow organisation. This will provide an AS7 subsystem and an installer
(ala Torquebox, Immutant etc) that will add the subsystem to an existing AS7
instance. There are several reasons why this will be developed outside the AS7
repository:

- Removes the potential for conflicts. If we were developing in a seperate AS7
branch we would either need to use merge commits or frequest rebases to keep
up with the AS7 tree, neither of which are particularly desirable option. -
Shorter build times. AS7 takes around an hour to build and fully test,
keeping this in a different repo initialy will make build/test times a lot
shorter.

- Easy of user adoption. This approach will make it much easier for AS7 users
to install undertow into their existing instance and test it out.





Security
========

The security handlers are primarily implemented as asynchronous handlers under 
the core module, this is for a couple of reasons.

* Allow authentication to occur in the call as early as possible.
* Allows for use of the mechanisms in numerous scenarios and not just for servlets.

The implementation makes use of a pair of handlers to coordinate the authentication
process with handlers for specific authentication mechanisms sandwiched between them.
The inbound exchange is expected to pass through the mechanism specific handler where 
each handler checks the incomming request for whatever it may require to perform 
authentication, if the mechanism handler can find what it needs then authentication is
performed and the call progresses to the next handler, this repeats until the 
`SecurityEndHandler` is reached.

The `SecurityEndHandler` is the final barrier for entry of the request, if this handler is 
reached and authentication is required but not completed the call will progress no further
and the `HttpCompletionHandler` will be called.  As the mechanism specific handlers were 
handling the incomming request they will also have been wrapping the `HTTPCompletionHandler`
with one of their own - at this point as the `HTTPCompletionHandlers` are being called they will
be setting their mechanism specific challenges in the response message being sent to the client.

![An Example Security Chain](https://raw.github.com/darranl/undertow-docs/security/images/security_handlers.png "An Example Security Chain") 

In this note that the handleComplete calls are shown as dotted lines as the are not really 
to the handler but to a `HttpCompletionHandler` registered by the handler.

Primarily the state of authentication is associated with the `HTTPServerExchange` however
in addition to this the state can also be associated with the `HttpServerConnection` or
the `Session` - how these additional stores are used is mechanism specific - as an example 
the HTTP Digest mechanism allows for a nonce to be only used for a short time, the 
`SecurityInitialHandler` should not undermine this by then using authentication date
in a session which has a long term ID and no replay protection.

To coordinate this the primary purpose of the `SecurityInitialHandler` is to create a 
`SecurityContext` and associate it with the current `HttpServerExchange`, one of the parameters
stored within the `SecurityContext` is an `AuthenticationState` which can take one of four
values: -

* **NOT_REQUIRED** - No security constraint has been identified that mandates authenitcation.
* **REQUIRED** - Authentication must be successful before the request can be processed.
* **AUTHENTICATED** - This request has been authenticated.
* **FAILED** - A failure occured authenticating this request, at this stage this does not differentiate between bad parameters or some other internal failure.

The following diagram shows the transitions between these states.

![Authentication States](https://raw.github.com/darranl/undertow-docs/security/images/authentication_states.png "Authentication States") 

The `SecurityInitialHandler` is responsible for setting the initial state to `REQUIRED` or `NOT_REQUIRED` 
based on the configured security constraints, the mechanism specific handlers will then perform 
the transitions to the other states as illustrated.  The `SecurityEndHandler` will then only 
allow the request to proceed if the state is either `NOT_REQUIRED` or `AUTHENTICATED`.

The transitions from `REQUIRED` are fairly self explanitory, if a mechanism specific handler
successfully authenticated the incomming request it will transition to `AUTHENTICATED`,
if there is any failure during the verification then it will set it to `FAILED`.  If the
incomming request does not contain the parameters required by the mechanism then no
transition will occur.

The transition from `NOT_REQUIRED` requires a little more description, these transitions
are to cover a scenario where the final applications being served up by the server
require access to a users identity if they have authenticated so in this situation 
depending on the mechanism there could be verifiable security tokens in the request
even though a challenge was not sent or there could be state already cached against the
`HTTPServerConnection` or within the `Session`.  The transition to `Authenticated` is the
simplest - that happens if the mechanism was able to confirm the authenticated state of
the user.  A transition to `Failed` would occur if the authentication can not be verfied
due to some internal error.  The transition to `Required` would be used for scenarios
where we have an authenticated user but the authentication is 'stale' this could be because
the nonce in a digest challenge has now expired or it could be because a previously valid
password is no longer valid.


