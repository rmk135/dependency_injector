.. _resource-provider:

Resource provider
=================

.. meta::
   :keywords: Python,DI,Dependency injection,IoC,Inversion of Control,Resource,Injection,
              Logging,Event Loop,Thread Pool
   :description: Resource provider provides a component with initialization and shutdown. It works
                 well for configuring logging, event loop, thread or process pool, etc.
                 This page demonstrates how to use resource provider.

.. currentmodule:: dependency_injector.providers

:py:class:`Resource` provider provides a component with initialization and shutdown.

.. literalinclude:: ../../examples/providers/resource.py
   :language: python
   :lines: 3-

Resource providers help to initialize and configure logging, event loop, thread or process pool, etc.

Resource provider is similar to ``Singleton``. Resource initialization happens only once.
You can make injections and use provided instance the same way like you do with any other provider.

.. code-block:: python
   :emphasize-lines: 12

   class Container(containers.DeclarativeContainer):

       config = providers.Configuration()

       thread_pool = providers.Resource(
           init_thread_pool,
           max_workers=config.max_workers,
       )

       dispatcher = providers.Factory(
           TaskDispatcher,
           executor=thread_pool,
       )

Container has an interface to initialize and shutdown all resources at once:

.. code-block:: python

   container = Container()
   container.init_resources()
   container.shutdown_resources()

You can also initialize and shutdown resources one-by-one using ``init()`` and
``shutdown()`` methods of the provider:

.. code-block:: python

   container = Container()
   container.thread_pool.init()
   container.thread_pool.shutdown()

When you call ``.shutdown()`` method on a resource provider, it will remove the reference to the initialized resource,
if any, and switch to uninitialized state. Some of resource initializer types support specifying custom
resource shutdown.

Resource provider supports 3 types of initializers:

- Function
- Generator
- Subclass of ``resources.Resource``

Function initializer
--------------------

Function is the most common way to specify resource initialization:

.. code-block:: python

   def init_resource(argument1=..., argument2=...):
       return SomeResource()


   class Container(containers.DeclarativeContainer):

       resource = providers.Resource(
           init_resource,
           argument1=...,
           argument2=...,
       )

Function initializer may not return a value. This often happens when
you configure global resource:

.. code-block:: python

   import logging.config


   class Container(containers.DeclarativeContainer):

       configure_logging = providers.Resource(
           logging.config.fileConfig,
           fname="logging.ini",
       )

Function initializer does not provide a way to specify custom resource shutdown.

Generator initializer
---------------------

Resource provider can use 2-step generators:

- First step of generator is an initialization phase
- The second is step is a shutdown phase

.. code-block:: python

   def init_resource(argument1=..., argument2=...):
       resource = SomeResource()  # initialization

       yield resource

       # shutdown
       ...


   class Container(containers.DeclarativeContainer):

       resource = providers.Resource(
           init_resource,
           argument1=...,
           argument2=...,
       )

Generator initialization phase ends on the first ``yield`` statement. You can return a
resource object using ``yield resource`` like in the example above. Returning of the
object is not mandatory. You can leave ``yield`` statement empty:

.. code-block:: python

   def init_resource(argument1=..., argument2=...):
       # initialization
       ...

       yield

       # shutdown
       ...


   class Container(containers.DeclarativeContainer):

       resource = providers.Resource(
           init_resource,
           argument1=...,
           argument2=...,
       )

Subclass initializer
--------------------

You can create resource initializer by implementing a subclass of the ``resources.Resource``:

.. code-block:: python

   from dependency_injector import resources


   class MyResource(resources.Resource):

       def init(self, argument1=..., argument2=...) -> SomeResource:
           return SomeResource()

       def shutdown(self, resource: SomeResource) -> None:
           # shutdown
           ...


   class Container(containers.DeclarativeContainer):

       resource = providers.Resource(
           MyResource,
           argument1=...,
           argument2=...,
       )

Subclass must implement two methods: ``init()`` and ``shutdown()``.

Method ``init()`` receives arguments specified in resource provider.
It performs initialization and returns resource object. Returning of the object
is not mandatory.

Method ``shutdown()`` receives resource object returned from ``init()``. If ``init()``
didn't return an object ``shutdown()`` method will be called anyway with ``None`` as a
first argument.

.. code-block:: python

   from dependency_injector import resources


   class MyResource(resources.Resource):

       def init(self, argument1=..., argument2=...) -> None:
           # initialization
           ...

       def shutdown(self, _: None) -> None:
           # shutdown
           ...


.. _resource-provider-wiring-closing:

Scoping Resources using specialized subclasses
----------------------------------------------

You can use specialized subclasses of ``Resource`` provider to initialize and shutdown resources by type.
Allowing for example to only initialize a subgroup of resources.

.. code-block:: python

   class ScopedResource(resources.Resource):
       pass

   def init_service(name) -> Service:
      print(f"Init {name}")
      yield Service()
      print(f"Shutdown {name}")

   class Container(containers.DeclarativeContainer):

       scoped = ScopedResource(
           init_service,
           "scoped",
       )

       generic = providers.Resource(
           init_service,
           "generic",
       )


To initialize resources by type you can use ``init_resources(resource_type)`` and ``shutdown_resources(resource_type)``
methods adding the resource type as an argument:

.. code-block:: python

   def main():
       container = Container()
       container.init_resources(ScopedResource)
       #  Generates:
       # >>> Init scoped

       container.shutdown_resources(ScopedResource)
       #  Generates:
       # >>> Shutdown scoped


And to initialize all resources you can use ``init_resources()`` and ``shutdown_resources()`` without arguments:

.. code-block:: python

   def main():
       container = Container()
       container.init_resources()
       #  Generates:
       # >>> Init scoped
       # >>> Init generic

       container.shutdown_resources()
       #  Generates:
       # >>> Shutdown scoped
       # >>> Shutdown generic


It works using the :ref:`traverse` method to find all resources of the specified type, selecting all resources
which are instances of the specified type.


Resources, wiring, and per-function execution scope
---------------------------------------------------

You can compound ``Resource`` provider with :ref:`wiring` to implement per-function
execution scope. For doing this you need to use additional ``Closing`` marker from
``wiring`` module.

.. literalinclude:: ../../examples/wiring/flask_resource_closing.py
   :language: python
   :lines: 3-
   :emphasize-lines: 22

Framework initializes and injects the resource into the function. With the ``Closing`` marker
framework calls resource ``shutdown()`` method when function execution is over.

The example above produces next output:

.. code-block:: bash

   Init service
   Shutdown service
   127.0.0.1 - - [29/Oct/2020 22:39:40] "GET / HTTP/1.1" 200 -
   Init service
   Shutdown service
   127.0.0.1 - - [29/Oct/2020 22:39:41] "GET / HTTP/1.1" 200 -
   Init service
   Shutdown service
   127.0.0.1 - - [29/Oct/2020 22:39:41] "GET / HTTP/1.1" 200 -

.. _resource-async-initializers:

Asynchronous initializers
-------------------------

When you write an asynchronous application, you might need to initialize resources asynchronously. Resource
provider supports asynchronous initialization and shutdown.

Asynchronous function initializer:

.. code-block:: python

   async def init_async_resource(argument1=..., argument2=...):
       return await connect()


   class Container(containers.DeclarativeContainer):

       resource = providers.Resource(
           init_resource,
           argument1=...,
           argument2=...,
       )

Asynchronous generator initializer:

.. code-block:: python

   async def init_async_resource(argument1=..., argument2=...):
       connection = await connect()
       yield connection
       await connection.close()


   class Container(containers.DeclarativeContainer):

       resource = providers.Resource(
           init_async_resource,
           argument1=...,
           argument2=...,
       )

Asynchronous subclass initializer:

.. code-block:: python

   from dependency_injector import resources


   class AsyncConnection(resources.AsyncResource):

       async def init(self, argument1=..., argument2=...):
           yield await connect()

       async def shutdown(self, connection):
           await connection.close()


   class Container(containers.DeclarativeContainer):

       resource = providers.Resource(
           AsyncConnection,
           argument1=...,
           argument2=...,
       )

When you use resource provider with asynchronous initializer you need to call its ``__call__()``,
``init()``, and ``shutdown()`` methods asynchronously:

.. code-block:: python

   import asyncio


   class Container(containers.DeclarativeContainer):

       connection = providers.Resource(init_async_connection)


   async def main():
       container = Container()
       connection = await container.connection()
       connection = await container.connection.init()
       connection = await container.connection.shutdown()


   if __name__ == "__main__":
       asyncio.run(main())

Container ``init_resources()`` and ``shutdown_resources()`` methods should be used asynchronously if there is
at least one asynchronous resource provider:

.. code-block:: python

   import asyncio


   class Container(containers.DeclarativeContainer):

       connection1 = providers.Resource(init_async_connection)

       connection2 = providers.Resource(init_sync_connection)


   async def main():
       container = Container()
       await container.init_resources()
       await container.shutdown_resources()


   if __name__ == "__main__":
       asyncio.run(main())

See also:

- Provider :ref:`async-injections`
- Wiring :ref:`async-injections-wiring`
- :ref:`fastapi-redis-example`


.. disqus::
