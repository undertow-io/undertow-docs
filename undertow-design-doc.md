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

Security within Undertow is implemented as a set of asynchronous handlers and a set of authentication
mechanisms co-ordinated by these handles.

* Allow authentication to occur in the call as early as possible.
* Allows for use of the mechanisms in numerous scenarios and not just for servlets.

Early in the call chain is a handler called `SecurityInitialHandler`, this is where the security processing
beings, this handler ensures that an empty `SecurityContext` is set on the current `HttpServerExchange`
and that any existing `SecurityContext` is removed.  As the call returns later this handler
is also responsible for removing the `SecurityContext` that was set and restoring the one remove.

The `SecurityContext` is responsible for both holding the state related to the currently authenticated user
and also for holding the configured `AuthenticationMechanism`s and providing methods to work with both of 
these.  As this `SecurityContext` is replacable and restorable then advanced configurations can be
achieve where a general configuration can be applied to a complete server with custom configuration
replacing it later in the call.

After the `SecurityContext` has been established subseqeunt handlers can then add `AuthenticationMechanism`s
to the context, to simplify this Undertow contains a handler called `AuthenticationMechanismsHandler`
this handler can be created with a set of `AuthenticationMechanism`s and will set them all on the 
established `SecurityContext`.  Alternatively custom handlers could be used to add mechanisms one at a time
bases on alternative requirements.

The next handler in the authentication process is the `AuthenticationConstraintHandler`, this handler is 
responsible for checking the current request and identifying if authentication should be marked as being
required for the current request.  The default implementation marks authentication as being required for
all requests that it handles - the handler can be extended and the `isAuthenticationRequired` method 
overriden to provide more complex checks.

The final handler in this chain is the `AuthenticationCallHandler`, this handler is responsible for 
ensuring the `SecurityContext` is called to actually perform the authentication process, depending 
on any identified constraint this will either mandate authentication or only perform authentication 
if appropriate for the configured mechanisms.

There is no requirement for these handlers to be executed consecutively, the only requirement is that first
the `SecurityContext` is established, then the `AuthenticationMechanism`s and constrain check can be 
performed in any order and finally the `AuthenticationCallHandler` but be called before any processing of
a potentially protected resource.

![An Example Security Chain](https://raw.github.com/darranl/undertow-docs/security/images/security_handlers.png "An Example Security Chain") 

Security mechanisms that are to be used must implement the following interface: -

        public interface AuthenticationMechanism {
            IoFuture<AuthenticationResult> authenticate(final HttpServerExchange exchange);
            void handleComplete(final HttpServerExchange exchange, final HttpCompletionHandler completionHandler);
        }

The `AuthenticationResult` is used by the mechanism to indicate the status of the attempted authentication and
is also used as the mechanism to return the Principal of the authenticated identity if authentication we
achieved.

        public class AuthenticationResult {
            private final Principal principle;
            private final AuthenticationOutcome outcome;

            public AuthenticationResult(final Principal principle, final AuthenticationOutcome outcome) { ... }
        }

The authentication process is split into two phases, the `INBOUND` phase and the `OUTBOUND` phase, the
`INBOUND` phase is only responsible for checking if authentication data has been received from the client
and using to attempt authentication if and only if it has been provided.  During the `INBOUND` phase the 
mechanisms are called sequentally (if we wanted to support multiple mechanisms succeeding concurently 
we could also execute these concurently although that would lead to multiple threads per request) -
a mechanism is caled in this phase by a call to `authenticate`.

When the `authenticate` method of the `AuthenticationMechanism` is called the outcome is indicated
using an `AuthenticationResult` with an `AuthenticationOutcome` of one of the following: -

* **AUTHENTICATED** - The mechanism has successfully authenticated the remote user.
* **NOT_ATTEMPTED** - The mechanism saw no applicable security tokens so did not attempt to authenticate the user.
* **NOT_AUTHENTICATED** - The mechanism attempted authentication but it either failed or requires an additional round trip to the client.

If the `AuthenticationOutcome` is `AUTHENTICATE` then a `Principal` must also be returned in the `AuthenticationResult`, the remaining
outcomes will not have a `Principal` to return.

The overall authentication process using the mechanisms run as follows: -

Regardless of if authentication has been flagged as being required when the request reaches the `AuthenticationCallHandler` the 
`SecurityContext` is called to commence the process.  The reason this happens regardless of if authentication is flagged as
required is for a few reasons: -
1 - The client may have sent additional authentication tokens and have expectations the response will take these into account.
2 - We may be able to verify the remote user without any additional rount trips, especially where authentication has already occurred.
3 - The authentication mechanism may need to pass intermediate updates to the client so we need to ensure any inbound tokens are valid.

When authentication runs the `authenticate` method on each configured `AuthenticationMechanism` is called in turn, this continues
untill one of the following occurs: -

1 - A mechanisms successfully authenticates the request and returns `AUTHENTICATED`.
2 - A mechanism attempts but does not complete authentication and returns `NOT_AUTHENTICATED`.
3 - The list of mechanisms is exhausted.

At this point if the response was `AUTHENTICATED` then the request will be allowed through and passed onto the next handler.

If the request is `NOT_AUTHENTICATED` then either authentication failed or a mechanism requires an additional round trip with the
client, either way the `handleComplete` method of each defined `AuthenticationMethod` is called in turn and the response sent back
to the client.  All mechanisms are called as even if one mechanism is mid-authentication the client can still decide to abandon
that mechanism and switch to an alternative mechanism so all challenges need to be re-sent.

If the list of mechanisms was exhausted then the previously set authentication constraint needs to be checked, if authentication was
not required then the request can proceed to the next handler in the chain and that will be then of authentication for this request
(unless a later handler mandates authentication and requests authentication is re-atempted).  If however authentication was required
then as with a `NOT_AUTHENTICATED` response each mechanism has `handleComplete` called in turn to generate an authentication challenge
to send to the client.

If request processing after calling the mechanisms is allowed through to the next handler and if no mechanism authenticated the 
incomming requests then the mechanisms are not called in the `OUTBOUND` phase - however if an `AuthenticationMechanism` did 
authenticate the client then regardless of if this was flagged as required the `handleComplete` method of that mechanism and only
that mechanism will be called.  The purpose of this is in case the mechanism needs to send further mechanism specific tokens
back to the client.

A mechanism can make the following call within the `handleComplete` method to check if it should be sending back a general
challenge or if it being called for an optional update: -

        if (Util.shouldChallenge(exchange)) { ... }



