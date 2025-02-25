"""Tests for container async resources."""

import asyncio

from dependency_injector import containers, providers
from pytest import mark, raises


@mark.asyncio
async def test_init_and_shutdown_ordering():
    """Test init and shutdown resources.

    Methods .init_resources() and .shutdown_resources() should respect resources dependencies.
    Initialization should first initialize resources without dependencies and then provide
    these resources to other resources. Resources shutdown should follow the same rule: first
    shutdown resources without initialized dependencies and then continue correspondingly
    until all resources are shutdown.
    """
    initialized_resources = []
    shutdown_resources = []

    async def _resource(name, delay, **_):
        await asyncio.sleep(delay)
        initialized_resources.append(name)

        yield name

        await asyncio.sleep(delay)
        shutdown_resources.append(name)

    class Container(containers.DeclarativeContainer):
        resource1 = providers.Resource(
            _resource,
            name="r1",
            delay=0.03,
        )
        resource2 = providers.Resource(
            _resource,
            name="r2",
            delay=0.02,
            r1=resource1,
        )
        resource3 = providers.Resource(
            _resource,
            name="r3",
            delay=0.01,
            r2=resource2,
        )

    container = Container()

    await container.init_resources()
    assert initialized_resources == ["r1", "r2", "r3"]
    assert shutdown_resources == []

    await container.shutdown_resources()
    assert initialized_resources == ["r1", "r2", "r3"]
    assert shutdown_resources == ["r3", "r2", "r1"]

    await container.init_resources()
    assert initialized_resources == ["r1", "r2", "r3", "r1", "r2", "r3"]
    assert shutdown_resources == ["r3", "r2", "r1"]

    await container.shutdown_resources()
    assert initialized_resources == ["r1", "r2", "r3", "r1", "r2", "r3"]
    assert shutdown_resources == ["r3", "r2", "r1", "r3", "r2", "r1"]


@mark.asyncio
async def test_shutdown_circular_dependencies_breaker():
    async def _resource(name, **_):
        yield name

    class Container(containers.DeclarativeContainer):
        resource1 = providers.Resource(
            _resource,
            name="r1",
        )
        resource2 = providers.Resource(
            _resource,
            name="r2",
            r1=resource1,
        )
        resource3 = providers.Resource(
            _resource,
            name="r3",
            r2=resource2,
        )

    container = Container()
    await container.init_resources()

    # Create circular dependency after initialization (r3 -> r2 -> r1 -> r3 -> ...)
    container.resource1.add_kwargs(r3=container.resource3)

    with raises(RuntimeError, match="Unable to resolve resources shutdown order"):
        await container.shutdown_resources()


@mark.asyncio
async def test_shutdown_sync_and_async_ordering():
    initialized_resources = []
    shutdown_resources = []

    def _sync_resource(name, **_):
        initialized_resources.append(name)
        yield name
        shutdown_resources.append(name)

    async def _async_resource(name, **_):
        initialized_resources.append(name)
        yield name
        shutdown_resources.append(name)

    class Container(containers.DeclarativeContainer):
        resource1 = providers.Resource(
            _sync_resource,
            name="r1",
        )
        resource2 = providers.Resource(
            _sync_resource,
            name="r2",
            r1=resource1,
        )
        resource3 = providers.Resource(
            _async_resource,
            name="r3",
            r2=resource2,
        )

    container = Container()

    await container.init_resources()
    assert initialized_resources == ["r1", "r2", "r3"]
    assert shutdown_resources == []

    await container.shutdown_resources()
    assert initialized_resources == ["r1", "r2", "r3"]
    assert shutdown_resources == ["r3", "r2", "r1"]

    await container.init_resources()
    assert initialized_resources == ["r1", "r2", "r3", "r1", "r2", "r3"]
    assert shutdown_resources == ["r3", "r2", "r1"]

    await container.shutdown_resources()
    assert initialized_resources == ["r1", "r2", "r3", "r1", "r2", "r3"]
    assert shutdown_resources == ["r3", "r2", "r1", "r3", "r2", "r1"]


@mark.asyncio
async def test_init_and_shutdown_scoped_resources():
    initialized_resources = []
    shutdown_resources = []

    def _sync_resource(name, **_):
        initialized_resources.append(name)
        yield name
        shutdown_resources.append(name)

    async def _async_resource(name, **_):
        initialized_resources.append(name)
        yield name
        shutdown_resources.append(name)


    class ResourceA(providers.Resource):
        pass


    class ResourceB(providers.Resource):
        pass


    class Container(containers.DeclarativeContainer):
        resource_a = ResourceA(
            _sync_resource,
            name="ra1",
        )
        resource_b1 = ResourceB(
            _sync_resource,
            name="rb1",
            r1=resource_a,
        )
        resource_b2 = ResourceB(
            _async_resource,
            name="rb2",
            r2=resource_b1,
        )

    container = Container()

    container.init_resources(resource_type=ResourceA)
    assert initialized_resources == ["ra1"]
    assert shutdown_resources == []

    container.shutdown_resources(resource_type=ResourceA)
    assert initialized_resources == ["ra1"]
    assert shutdown_resources == ["ra1"]

    await container.init_resources(resource_type=ResourceB)
    assert initialized_resources == ["ra1", "ra1", "rb1", "rb2"]
    assert shutdown_resources == ["ra1"]

    await container.shutdown_resources(resource_type=ResourceB)
    assert initialized_resources == ["ra1", "ra1", "rb1", "rb2"]
    assert shutdown_resources == ["ra1", "rb2", "rb1"]


@mark.asyncio
async def test_init_and_shutdown_all_scoped_resources_using_default_value():
    initialized_resources = []
    shutdown_resources = []

    def _sync_resource(name, **_):
        initialized_resources.append(name)
        yield name
        shutdown_resources.append(name)

    async def _async_resource(name, **_):
        initialized_resources.append(name)
        yield name
        shutdown_resources.append(name)


    class ResourceA(providers.Resource):
        pass


    class ResourceB(providers.Resource):
        pass


    class Container(containers.DeclarativeContainer):
        resource_a = ResourceA(
            _sync_resource,
            name="r1",
        )
        resource_b1 = ResourceB(
            _sync_resource,
            name="r2",
            r1=resource_a,
        )
        resource_b2 = ResourceB(
            _async_resource,
            name="r3",
            r2=resource_b1,
        )

    container = Container()

    await container.init_resources()
    assert initialized_resources == ["r1", "r2", "r3"]
    assert shutdown_resources == []

    await container.shutdown_resources()
    assert initialized_resources == ["r1", "r2", "r3"]
    assert shutdown_resources == ["r3", "r2", "r1"]

    await container.init_resources()
    assert initialized_resources == ["r1", "r2", "r3", "r1", "r2", "r3"]
    assert shutdown_resources == ["r3", "r2", "r1"]

    await container.shutdown_resources()
    assert initialized_resources == ["r1", "r2", "r3", "r1", "r2", "r3"]
    assert shutdown_resources == ["r3", "r2", "r1", "r3", "r2", "r1"]
