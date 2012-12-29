/*
 * Author: Landon Fuller <landonf@bikemonkey.org>
 *
 * Copyright (c) 2012 Plausible Labs Cooperative, Inc.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */

#import "PLCrashMachExceptionServer.h"
#import "PLCrashReporterNSError.h"
#import "PLCrashAsync.h"

#import <pthread.h>
#import <mach/mach.h>
#import <mach/exc.h>


/**
 * @internal
 * Mask of monitored fatal exceptions.
 *
 * @warning Must be kept in sync with exception_to_mask();
 */
static const exception_mask_t FATAL_EXCEPTION_MASK = EXC_MASK_BAD_ACCESS |
                                                     EXC_MASK_BAD_INSTRUCTION |
                                                     EXC_MASK_ARITHMETIC |
                                                     EXC_MASK_BREAKPOINT;

/**
 * @internal
 * Map an exception type to its corresponding mask value.
 *
 * @note This only needs to handle the values listed in FATAL_EXCEPTION_MASK.
 */
static exception_mask_t exception_to_mask (exception_type_t exception) {
#define EXM(n) case EXC_ ## n: return EXC_MASK_ ## n;
    switch (exception) {
        EXM(BAD_ACCESS);
        EXM(BAD_INSTRUCTION);
        EXM(ARITHMETIC);
        EXM(EMULATION);
        EXM(BREAKPOINT);
        EXM(SOFTWARE);
        EXM(SYSCALL);
        EXM(MACH_SYSCALL);
        EXM(RPC_ALERT);
        EXM(CRASH);
    }
#undef EXM

    PLCF_DEBUG("No mapping available from exception type 0x%d to an exception mask", exception);
    return 0;
}

/**
 * @internal
 *
 * Exception state as returned by task_get_exception_ports(). Up
 * to EXC_TYPES_COUNT entries may be returned. The actual count
 * is provided via exception_handler_state::count. The values
 * stored in the arrays correspond positionally.
 */
struct exception_handler_state {
    /** Number of independent mask/port/behavior/flavor sets
     * (up to EXC_TYPES_COUNT). */
    mach_msg_type_number_t count;

    /** Exception masks. */
    exception_mask_t masks[EXC_TYPES_COUNT];

    /** Exception ports. */
    mach_port_t ports[EXC_TYPES_COUNT];

    /** Exception behaviors. */
    exception_behavior_t behaviors[EXC_TYPES_COUNT];

    /** Exception thread flavors. */
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
};

/**
 * Exception handler context.
 */
struct exception_server_context {
    /** The target mach task. */
    task_t task;

    /** Registered exception port. */
    mach_port_t server_port;

    /** Lock used to signal waiting initialization thread. */
    pthread_mutex_t server_init_lock;
    
    /** Condition used to signal waiting initialization thread. */
    pthread_cond_t server_init_cond;
    
    /** Intended to be observed by the waiting initialization thread. Informs
     * the waiting thread that initialization has completed . */
    bool server_init_done;

    /** Intended to be observed by the waiting initialization thread. Contains
     * the result of setting the task exception handler. */
    kern_return_t server_init_result;

    /** Previously registered handlers. We will forward all exceptions here after
      * internal processing. */
    struct exception_handler_state prev_handler_state;
};

/**
 * @internal
 *
 * Set exception ports defined in @a state for @a task.
 *
 * @param task The task for which the exception handler(s) were registered.
 * @param state Exception handler state.
 */
static void set_exception_ports (task_t task, struct exception_handler_state *state) {
    kern_return_t kr;
    for (mach_msg_type_number_t i = 0; i < state->count; ++i) {
        kr = task_set_exception_ports(task, state->masks[i], state->ports[i], state->behaviors[i], state->flavors[i]);

        /* Report errors, but continue to restore any remaining exception ports */
        if (kr != KERN_SUCCESS)
            PLCF_DEBUG("Failed to restore task exception ports: %x", kr);
    }
}

/**
 * Background exception server. Handles incoming exception messages and dispatches
 * them to the registered callback.
 *
 * This code must be written to be async-safe once a Mach exception message
 * has been returned, as the state of the process' threads is entirely unknown.
 */
static void *exception_server_thread (void *arg) {
    struct exception_server_context *exc_context = arg;
    __Request__exception_raise_t *request = NULL;
    __Reply__exception_raise_t reply;
    size_t request_size;
    kern_return_t kr;
    mach_msg_return_t mr;

    /* Atomically swap in our up the exception handler, also informing the waiting thread of
     * completion (or failure). */
    pthread_mutex_lock(&exc_context->server_init_lock); {
        kr = task_swap_exception_ports(exc_context->task,
                                       FATAL_EXCEPTION_MASK,
                                       exc_context->server_port,
                                       EXCEPTION_DEFAULT,
                                       THREAD_STATE_NONE,
                                       exc_context->prev_handler_state.masks,
                                       &exc_context->prev_handler_state.count,
                                       exc_context->prev_handler_state.ports,
                                       exc_context->prev_handler_state.behaviors,
                                       exc_context->prev_handler_state.flavors);
        exc_context->server_init_result = kr;
        exc_context->server_init_done = true;

        /* Notify our spawning thread of our initialization */
        pthread_cond_signal(&exc_context->server_init_cond);

        /* Exit on error. If a failure occured, it's now unsafe to access exc_server; the spawning
         * thread may have already deallocated it. */
        if (kr != KERN_SUCCESS) {
            pthread_mutex_unlock(&exc_context->server_init_lock);
            return NULL;
        }
    } pthread_mutex_unlock(&exc_context->server_init_lock);

    /* Initialize the default reply message */
    memset(&reply, 0, sizeof(reply));

    /* Initialize the received message with a default size */
    request_size = round_page(sizeof(*request));
    kr = vm_allocate(mach_task_self(), (vm_address_t *) &request, request_size, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        /* Shouldn't happen ... */
        fprintf(stderr, "Unexpected error in vm_allocate(): %x\n", kr);
        return NULL;
    }

    /* Wait for an exception message */
    while (true) {
        /* Initialize our request message */
        request->Head.msgh_local_port = exc_context->server_port;
        request->Head.msgh_size = request_size;
        mr = mach_msg(&request->Head,
                      MACH_RCV_MSG | MACH_RCV_LARGE,
                      0,
                      request->Head.msgh_size,
                      exc_context->server_port,
                      MACH_MSG_TIMEOUT_NONE,
                      MACH_PORT_NULL);

        /* Handle recoverable errors */
        if (mr != MACH_MSG_SUCCESS && mr == MACH_RCV_TOO_LARGE) {
            /* Determine the new size (before dropping the buffer) */
            request_size = round_page(request->Head.msgh_size);

            /* Drop the old receive buffer */
            vm_deallocate(mach_task_self(), (vm_address_t) request, request_size);

            /* Re-allocate a larger receive buffer */
            kr = vm_allocate(mach_task_self(), (vm_address_t *) &request, request_size, VM_FLAGS_ANYWHERE);
            if (kr != KERN_SUCCESS) {
                /* Shouldn't happen ... */
                fprintf(stderr, "Unexpected error in vm_allocate(): 0x%x\n", kr);
                return NULL;
            }

            continue;

        /* Handle fatal errors */
        } else if (mr != MACH_MSG_SUCCESS) {
            // TODO - handle MACH_RCV_INTERRUPTED and/or thread shutdown

            /* Shouldn't happen ... */
            PLCF_DEBUG("Unexpected error in mach_msg(): 0x%x. Restoring exception ports and stopping server thread.", mr);

            /* Restore exception ports; we won't be around to handle future exceptions */
            set_exception_ports(exc_context->task, &exc_context->prev_handler_state);

            break;

        /* Success! */
        } else {
            /* Restore exception ports; we don't want to double-fault if our exception handler crashes */
            set_exception_ports(exc_context->task, &exc_context->prev_handler_state);
        
            // TODO - Call handler
            PLCF_DEBUG("Got mach exception message. exc=%x code=%x,%x ctx=%p", request->exception, request->code[0], request->code[1], exc_context);

            /* Forward exception. */
            exception_mask_t fwd_mask = exception_to_mask(request->exception);
            bool forwarded = false;
            kern_return_t forward_result = KERN_SUCCESS;

            for (mach_msg_type_number_t i = 0; i < exc_context->prev_handler_state.count; i++) {
                if ((exc_context->prev_handler_state.masks[i] & fwd_mask) == 0)
                    continue;

                // TODO - handle state/identity behaviors
                if (exc_context->prev_handler_state.behaviors[i] != EXCEPTION_DEFAULT) {
                    PLCF_DEBUG("TODO: Unhandled exception port behavior: 0x%x for port %d", exc_context->prev_handler_state.behaviors[i], exc_context->prev_handler_state.ports[i]);
                    continue;
                }

                /* Re-raise the exception with the existing handler */
                forward_result = exception_raise(exc_context->prev_handler_state.ports[i],
                                                 request->thread.name,
                                                 request->task.name,
                                                 request->exception,
                                                 request->code,
                                                 request->codeCnt);
                forwarded = true;
                break;
            }
            
            /* Reply to the message */
            PLCF_DEBUG("Replying to message (ctx=%p, forwarded=%d, forwarded_result=%d)", exc_context, forwarded, forward_result);
            reply.Head.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(request->Head.msgh_bits), 0);
            reply.Head.msgh_local_port = MACH_PORT_NULL;
            reply.Head.msgh_remote_port = request->Head.msgh_remote_port;
            reply.Head.msgh_size = sizeof(reply);
            reply.NDR = NDR_record;

            /* If the message was forwarded, provide the handler's reply. Otherwise, we're the final handler; inform the kernel that the
             * thread should not be resumed (ie, the exception was not 'handled') */
            if (forwarded) {
                reply.RetCode = forward_result;
            } else {
                reply.RetCode = KERN_FAILURE;
            }

            /*
             * Mach uses reply id offsets of 100. This is rather arbitrary, and in theory could be changed
             * in a future iOS release (although, it has stayed constant for nearly 24 years, so it seems unlikely
             * to change now)
             *
             * TODO: File a Radar and/or leverage a Technical Support Incident to get a straight answer on the
             * undefined edge cases.
             */
            reply.Head.msgh_id = request->Head.msgh_id + 100;

            mr = mach_msg(&reply.Head, MACH_SEND_MSG, reply.Head.msgh_size, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
            if (mr != MACH_MSG_SUCCESS)
                PLCF_DEBUG("Unexpected failure replying to Mach exception message: 0x%x", mr);

            break;
        }
    }
    
    /* Drop the receive buffer */
    if (request != NULL)
        vm_deallocate(mach_task_self(), (vm_address_t) request, request_size);

    return NULL;
}


/***
 * @internal
 * Implements Crash Reporter mach exception handling.
 */
@implementation PLCrashMachExceptionServer

/**
 * Initialize a new Mach exception server. The exception server will
 * not register itself in the handler chain until PLCrashMachExceptionServer::registerHandlerAndReturnError:
 * is called.
 */
- (id) init {
    if ((self = [super init]) == nil)
        return nil;

    return self;
}

/**
 * Register the task signal handlers with the provided callback.
 * Should not be called more than once.
 *
 * @note If this method returns NO, the exception handler will remain unmodified.
 * @note Inserting a new Mach task handlers is performed atomically, and multiple handlers
 * may be initialized concurrently.
 *
 * @param task The mach task for which the handler should be registered.
 * @param callback Callback called upon receipt of an exception. The callback will execute
 * on the exception server's thread, distinctly from the crashed thread.
 * @param context Context to be passed to the callback. May be NULL.
 * @param outError A pointer to an NSError object variable. If an error occurs, this
 * pointer will contain an error object indicating why the signal handlers could not be
 * registered. If no error occurs, this parameter will be left unmodified. You may specify
 * NULL for this parameter, and no error information will be provided.
 */
- (BOOL) registerHandlerForTask: (task_t) task
                   withCallback: (PLCrashMachExceptionHandlerCallback) callback
                        context: (void *) context
                          error: (NSError **) outError
{
    struct exception_server_context *exc_context = NULL;
    pthread_attr_t attr;
    pthread_t thr;
    kern_return_t kr;

    /* Initialize the bare context. */
    exc_context = calloc(1, sizeof(*exc_context));
    exc_context->task = task;
    exc_context->server_port = MACH_PORT_NULL;
    exc_context->server_init_result = KERN_SUCCESS;

    if (pthread_mutex_init(&exc_context->server_init_lock, NULL) != 0) {
        plcrash_populate_posix_error(outError, errno, @"Mutex initialization failed");
        free(exc_context);
        return NO;
    }

    if (pthread_cond_init(&exc_context->server_init_cond, NULL) != 0) {
        plcrash_populate_posix_error(outError, errno, @"Condition initialization failed");
        free(exc_context);
        return NO;
    }

    /*
     * Initalize our server's port
     */
    kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &exc_context->server_port);
    if (kr != KERN_SUCCESS) {
        plcrash_populate_mach_error(outError, kr, @"Failed to allocate exception server's port");
        goto error;
    }

    kr = mach_port_insert_right(mach_task_self(), exc_context->server_port, exc_context->server_port, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        plcrash_populate_mach_error(outError, kr, @"Failed to add send right to exception server's port");
        goto error;
    }
    
    /* Spawn the server thread. The server thread will be responsible for actually setting the task exception
     * ports; this must happen last, as we gaurantee that the new exception ports will be either fully configured,
     * or left unchanged, and pthread_create() may fail. */
    {
        if (pthread_attr_init(&attr) != 0) {
            plcrash_populate_posix_error(outError, errno, @"Failed to initialize pthread_attr");
            goto error;
        }

        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        // TODO - A custom stack should be specified, using high/low guard pages to help prevent overwriting the stack
        // by crashing code.
        // pthread_attr_setstack(&attr, sp, stacksize);
        
        if (pthread_create(&thr, &attr, &exception_server_thread, exc_context) != 0) {
            plcrash_populate_posix_error(outError, errno, @"Failed to create exception server thread");
            pthread_attr_destroy(&attr);
            goto error;
        }
        
        pthread_attr_destroy(&attr);
    }

    pthread_mutex_lock(&exc_context->server_init_lock);
    
    while (!exc_context->server_init_done)
        pthread_cond_wait(&exc_context->server_init_cond, &exc_context->server_init_lock);

    if (exc_context->server_init_result != KERN_SUCCESS) {
        plcrash_populate_mach_error(outError, exc_context->server_init_result, @"Failed to set task exception ports");
        goto error;
    }
    pthread_mutex_unlock(&exc_context->server_init_lock);

    return YES;

error:
    if (exc_context != NULL) {
        if (exc_context->server_port != MACH_PORT_NULL)
            mach_port_deallocate(mach_task_self(), exc_context->server_port);

        pthread_cond_destroy(&exc_context->server_init_cond);
        pthread_mutex_destroy(&exc_context->server_init_lock);

        free(exc_context);
    }

    return NO;
}

@end
