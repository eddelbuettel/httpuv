#' HTTP and WebSocket server
#' 
#' Allows R code to listen for and interact with HTTP and WebSocket clients, so 
#' you can serve web traffic directly out of your R process. Implementation is
#' based on \href{https://github.com/joyent/libuv}{libuv} and
#' \href{https://github.com/joyent/http-parser}{http-parser}.
#' 
#' This is a low-level library that provides little more than network I/O and 
#' implementations of the HTTP and WebSocket protocols. For an easy way to 
#' create web applications, try \href{http://rstudio.com/shiny/}{Shiny} instead.
#' 
#' @examples
#' \dontrun{
#' demo("echo", package="httpuv")
#' }
#' 
#' @seealso startServer
#'   
#' @name httpuv-package
#' @aliases httpuv
#' @docType package
#' @title HTTP and WebSocket server
#' @author Joe Cheng \email{joe@@rstudio.com}
#' @keywords package
#' @useDynLib httpuv
NULL

AppWrapper <- setRefClass(
  'AppWrapper',
  fields = list(
    .app = 'ANY',
    .wsconns = 'environment'
  ),
  methods = list(
    initialize = function(app) {
      .app <<- app
    },
    call = function(req) {
      result <- try({
        resp <- .app$call(req)
        if ('file' %in% names(resp$body)) {
          filename <- resp$body[['file']]
          resp$body <- readBin(filename, raw(), file.info(filename)$size)
        }
        resp
      })
      if (inherits(result, 'try-error')) {
        return(list(
          status=500L,
          headers=list(
            'Content-Type'='text/plain'
          ),
          body=charToRaw(
            paste("ERROR:", attr(result, "condition")$message, collapse="\n"))
        ))
      } else {
        return(result)
      }
    },
    onWSOpen = function(handle) {
      ws <- WebSocket$new(handle)
      .wsconns[[as.character(handle)]] <<- ws
      result <- try(.app$onWSOpen(ws))
      
      # If an unexpected error happened, just close up
      if (inherits(result, 'try-error')) {
        # TODO: Close code indicating error?
        ws$close()
      }
    },
    onWSMessage = function(handle, binary, message) {
      for (handler in .wsconns[[as.character(handle)]]$.messageCallbacks) {
        result <- try(handler(binary, message))
        if (inherits(result, 'try-error')) {
          # TODO: Close code indicating error?
          .wsconns[[as.character(handle)]]$close()
          return()
        }
      }
    },
    onWSClose = function(handle) {
      ws <- .wsconns[[as.character(handle)]]
      ws$.handle <- NULL
      rm(list=as.character(handle), pos=.wsconns)
      for (handler in ws$.closeCallbacks) {
        handler()
      }
    }
  )
)

#' WebSocket object
#' 
#' An object that represents a single WebSocket connection. The object can be
#' used to send messages and close the connection, and to receive notifications
#' when messages are received or the connection is closed.
#' 
#' WebSocket objects should never be created directly. They are obtained by
#' passing an \code{onWSOpen} function to \code{\link{startServer}}.
#' 
#' \strong{Methods}
#' 
#'   \describe{
#'     \item{\code{onMessage(func)}}{
#'       Registers a callback function that will be invoked whenever a message
#'       is received on this connection. The callback function will be invoked
#'       with two arguments. The first argument is \code{TRUE} if the message
#'       is binary and \code{FALSE} if it is text. The second argument is either
#'       a raw vector (if the message is binary) or a character vector.
#'     }
#'     \item{\code{onClose(func)}}{
#'       Registers a callback function that will be invoked when the connection
#'       is closed.
#'     }
#'     \item{\code{send(message)}}{
#'       Begins sending the given message over the websocket. The message must
#'       be either a raw vector, or a single-element character vector that is
#'       encoded in UTF-8.
#'     }
#'     \item{\code{close()}}{
#'       Closes the websocket connection.
#'     }
#'   }
#' 
#' @export
WebSocket <- setRefClass(
  'WebSocket',
  fields = list(
    '.handle' = 'ANY',
    '.messageCallbacks' = 'list',
    '.closeCallbacks' = 'list'
  ),
  methods = list(
    initialize = function(handle) {
      .handle <<- handle
    },
    onMessage = function(func) {
      .messageCallbacks <<- c(.messageCallbacks, func)
    },
    onClose = function(func) {
      .closeCallbacks <<- c(.closeCallbacks, func)
    },
    send = function(message) {
      if (is.null(.handle))
        stop("Can't send message on a closed WebSocket")
      
      if (is.raw(message))
        sendWSMessage(.handle, TRUE, message)
      else {
        # TODO: Ensure that message is UTF-8 encoded
        sendWSMessage(.handle, FALSE, as.character(message))
      }
    },
    close = function() {
      if (is.null(.handle))
        return()
      
      closeWS(.handle)
    }
  )
)

#' Create an HTTP/WebSocket server
#' 
#' Creates an HTTP/WebSocket server on the specified host and port.
#' 
#' @param host A string that is a valid IPv4 address that is owned by this 
#'   server, or \code{"0.0.0.0"} to listen on all IP addresses.
#' @param port A number or integer that indicates the server port that should be
#'   listened on. Note that on most Unix-like systems including Linux and Mac OS
#'   X, port numbers smaller than 1025 require root privileges.
#' @param app A collection of functions that define your application. See 
#'   Details.
#' @return A handle for this server that can be passed to \code{\link{stopServer}}
#'   to shut the server down.
#'   
#' @details \code{startServer} binds the specified port, but no connections are 
#'   actually accepted. See \code{\link{service}}, which should be called 
#'   repeatedly in order to actually accept and handle connections. If the port
#'   cannot be bound (most likely due to permissions or because it is already
#'   bound), an error is raised.
#'   
#'   The \code{app} parameter is where your application logic will be provided 
#'   to the server. This can be a list, environment, or reference class that 
#'   contains the following named functions/methods:
#'   
#'   \describe{
#'     \item{\code{call(req)}}{Process the given HTTP request, and return an
#'   HTTP response. [TODO: Link to Rook documentation]}
#'     \item{\code{onWSOpen(ws)}}{Called back when a WebSocket connection is established.
#'     The given object can be used to be notified when a message is received from
#'     the client, to send messages to the client, etc. See \code{\link{WebSocket}}.}
#'   }
#' @seealso \code{\link{runServer}}
#' @export
startServer <- function(host, port, app) {
  
  appWrapper <- AppWrapper$new(app)
  server <- makeServer(host, port,
                       appWrapper$call,
                       appWrapper$onWSOpen,
                       appWrapper$onWSMessage,
                       appWrapper$onWSClose)
  if (is.null(server)) {
    stop("Failed to create server")
  }
  return(server)
}

#' Process requests
#' 
#' Process HTTP requests and WebSocket messages. Even if a server exists, no
#' requests are serviced unless and until \code{service} is called.
#' 
#' Note that while \code{service} is waiting for a new request, the process is
#' not interruptible using normal R means (Esc, Ctrl+C, etc.). If being
#' interruptible is a requirement, then call \code{service} in a while loop
#' with a very short but non-zero \code{\link{Sys.sleep}} during each iteration.
#' 
#' @param timeoutMs Approximate number of milliseconds to run before returning. 
#'   If 0, then the function will continually process requests without returning
#'   unless an error occurs.
#'
#' @examples
#' \dontrun{
#' while (TRUE) {
#'   service()
#'   Sys.sleep(0.001)
#' }
#' }
#' 
#' @export
service <- function(timeoutMs = ifelse(interactive(), 100, 1000)) {
  run(timeoutMs)
}

#' Stop a running server
#' 
#' Given a handle that was returned from a previous invocation of 
#' \code{\link{startServer}}, closes all open connections for that server and 
#' unbinds the port. \strong{Be careful not to call \code{stopServer} more than 
#' once on a handle, as this will cause the R process to crash!}
#' 
#' @param handle A handle that was previously returned from
#'   \code{\link{startServer}}.
#'   
#' @export
stopServer <- function(handle) {
  destroyServer(handle)
}

#' Run a server
#' 
#' This is a convenience function that provides a simple way to call 
#' \code{\link{startServer}}, \code{\link{service}}, and 
#' \code{\link{stopServer}} in the correct sequence. It does not return unless 
#' interrupted or an error occurs.
#' 
#' If you have multiple hosts and/or ports to listen on, call the individual 
#' functions instead of \code{runServer}.
#' 
#' @param host A string that is a valid IPv4 address that is owned by this 
#'   server, or \code{"0.0.0.0"} to listen on all IP addresses.
#' @param port A number or integer that indicates the server port that should be
#'   listened on. Note that on most Unix-like systems including Linux and Mac OS
#'   X, port numbers smaller than 1025 require root privileges.
#' @param app A collection of functions that define your application. See 
#'   Details.
#' @param interruptIntervalMs How often to check for interrupt. The default 
#'   should be appropriate for most situations.
#'   
#' @seealso \code{\link{startServer}}, \code{\link{service}},
#'   \code{\link{stopServer}}
#' @export
runServer <- function(host, port, app,
                      interruptIntervalMs = ifelse(interactive(), 100, 1000)) {
  server <- startServer(host, port, app)
  on.exit(stopServer(server))
  
  while (TRUE) {
    service(interruptIntervalMs)
    Sys.sleep(0.001)
  }
}