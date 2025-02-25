"""Containers module."""

import contextlib
import copy as copy_module
import json
import sys
import importlib
import inspect
import warnings

try:
    import asyncio
except ImportError:
    asyncio = None

try:
    import yaml
except ImportError:
    yaml = None

from . import providers, errors
from .providers cimport __is_future_or_coroutine


if sys.version_info[:2] >= (3, 6):
    from .wiring import wire, unwire
else:
    def wire(*args, **kwargs):
        raise NotImplementedError("Wiring requires Python 3.6 or above")

    def unwire(*args, **kwargs):
        raise NotImplementedError("Wiring requires Python 3.6 or above")

if sys.version_info[:2] == (3, 5):
    warnings.warn(
        "Dependency Injector will drop support of Python 3.5 after Jan 1st of 2022. "
        "This does not mean that there will be any immediate breaking changes, "
        "but tests will no longer be executed on Python 3.5, and bugs will not be addressed.",
        category=DeprecationWarning,
    )


class WiringConfiguration:
    """Container wiring configuration."""

    def __init__(self, modules=None, packages=None, from_package=None, auto_wire=True):
        self.modules = [*modules] if modules else []
        self.packages = [*packages] if packages else []
        self.from_package = from_package
        self.auto_wire = auto_wire

    def __deepcopy__(self, memo=None):
        return self.__class__(self.modules, self.packages, self.from_package, self.auto_wire)


class Container(object):
    """Abstract container."""


class DynamicContainer(Container):
    """Dynamic inversion of control container.

    .. code-block:: python

        services = DynamicContainer()
        services.auth = providers.Factory(AuthService)
        services.users = providers.Factory(UsersService,
                                           auth_service=services.auth)

    .. py:attribute:: providers

        Read-only dictionary of all providers.

        :type: dict[str, :py:class:`dependency_injector.providers.Provider`]

    .. py:attribute:: overridden

        Tuple of overriding containers.

        :type: tuple[:py:class:`DynamicContainer`]

    .. py:attribute:: provider_type

        Type of providers that could be placed in container.

        :type: type
    """

    __IS_CONTAINER__ = True

    def __init__(self):
        """Initializer.

        :rtype: None
        """
        self.provider_type = providers.Provider
        self.providers = {}
        self.overridden = tuple()
        self.parent = None
        self.declarative_parent = None
        self.wiring_config = WiringConfiguration()
        self.wired_to_modules = []
        self.wired_to_packages = []
        self.__self__ = providers.Self(self)
        super(DynamicContainer, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of container."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = self.__class__()
        memo[id(self)] = copied

        copied.__self__ = providers.deepcopy(self.__self__, memo)
        for name in copied.__self__.alt_names:
            copied.set_provider(name, copied.__self__)

        copied.provider_type = providers.Provider
        copied.overridden = providers.deepcopy(self.overridden, memo)
        copied.wiring_config = copy_module.deepcopy(self.wiring_config, memo)
        copied.declarative_parent = self.declarative_parent

        for name, provider in providers.deepcopy(self.providers, memo).items():
            copied.set_provider(name, provider)

        copied.parent = providers.deepcopy(self.parent, memo)

        return copied

    def __setattr__(self, name, value):
        """Set instance attribute.

        If value of attribute is provider, it will be added into providers
        dictionary.

        :param name: Attribute name
        :type name: object

        :param value: Attribute value
        :type value: object

        :rtype: None
        """
        if isinstance(value, providers.Provider) \
                and not isinstance(value, providers.Self) \
                and name != "parent":
            _check_provider_type(self, value)

            self.providers[name] = value

            if isinstance(value, providers.CHILD_PROVIDERS):
                value.assign_parent(self)

        super(DynamicContainer, self).__setattr__(name, value)

    def __delattr__(self, name):
        """Delete instance attribute.

        If value of attribute is provider, it will be deleted from providers
        dictionary.

        :param name: Attribute name
        :type name: object

        :rtype: None
        """
        if name in self.providers:
            del self.providers[name]
        super(DynamicContainer, self).__delattr__(name)

    @property
    def dependencies(self):
        """Return dependency providers dictionary.

        Dependency providers can be both of :py:class:`dependency_injector.providers.Dependency` and
        :py:class:`dependency_injector.providers.DependenciesContainer`.

        :rtype:
            dict[str, :py:class:`dependency_injector.providers.Provider`]
        """
        return {
            name: provider
            for name, provider in self.providers.items()
            if isinstance(provider, (providers.Dependency, providers.DependenciesContainer))
        }

    def traverse(self, types=None):
        """Return providers traversal generator."""
        yield from providers.traverse(*self.providers.values(), types=types)

    def set_providers(self, **providers):
        """Set container providers.

        :param providers: Dictionary of providers
        :type providers:
            dict[object, :py:class:`dependency_injector.providers.Provider`]

        :rtype: None
        """
        for name, provider in providers.items():
            setattr(self, name, provider)

    def set_provider(self, name, provider):
        """Set container provider.

        :param name: Provider name
        :type name: str

        :param provider: Provider
        :type provider: :py:class:`dependency_injector.providers.Provider`

        :rtype: None
        """
        setattr(self, name, provider)

    def override(self, object overriding):
        """Override current container by overriding container.

        :param overriding: Overriding container.
        :type overriding: :py:class:`DynamicContainer`

        :raise: :py:exc:`dependency_injector.errors.Error` if trying to
                override container by itself

        :rtype: None
        """
        if overriding is self:
            raise errors.Error("Container {0} could not be overridden "
                               "with itself".format(self))

        self.overridden += (overriding,)

        for name, provider in overriding.providers.items():
            try:
                getattr(self, name).override(provider)
            except AttributeError:
                pass

    def override_providers(self, **overriding_providers):
        """Override container providers.

        :param overriding_providers: Dictionary of providers
        :type overriding_providers:
            dict[str, :py:class:`dependency_injector.providers.Provider`]

        :rtype: None
        """
        overridden_providers = []
        for name, overriding_provider in overriding_providers.items():
            container_provider = getattr(self, name)
            container_provider.override(overriding_provider)
            overridden_providers.append(container_provider)
        return ProvidersOverridingContext(self, overridden_providers)

    def reset_last_overriding(self):
        """Reset last overriding provider for each container providers.

        :rtype: None
        """
        if not self.overridden:
            raise errors.Error("Container {0} is not overridden".format(self))

        self.overridden = self.overridden[:-1]

        for provider in self.providers.values():
            provider.reset_last_overriding()

    def reset_override(self):
        """Reset all overridings for each container providers.

        :rtype: None
        """
        self.overridden = tuple()

        for provider in self.providers.values():
            provider.reset_override()

    def is_auto_wiring_enabled(self):
        """Check if auto wiring is needed."""
        return self.wiring_config.auto_wire is True

    def wire(self, modules=None, packages=None, from_package=None):
        """Wire container providers with provided packages and modules.

        :rtype: None
        """
        if modules is None and self.wiring_config.modules:
            modules = self.wiring_config.modules
        if packages is None and self.wiring_config.packages:
            packages = self.wiring_config.packages

        modules = [*modules] if modules else []
        packages = [*packages] if packages else []

        if _any_relative_string_imports_in(modules) or _any_relative_string_imports_in(packages):
            if from_package is None:
                if self.wiring_config.from_package is not None:
                    from_package = self.wiring_config.from_package
                elif self.declarative_parent is not None \
                        and (self.wiring_config.modules or self.wiring_config.packages):
                    with contextlib.suppress(Exception):
                        from_package = _resolve_package_name_from_cls(self.declarative_parent)
                else:
                    with contextlib.suppress(Exception):
                        from_package = _resolve_calling_package_name()

        modules = _resolve_string_imports(modules, from_package)
        packages = _resolve_string_imports(packages, from_package)

        if not modules and not packages:
            return

        wire(
            container=self,
            modules=modules,
            packages=packages,
        )

        if modules:
            self.wired_to_modules.extend(modules)
        if packages:
            self.wired_to_packages.extend(packages)

    def unwire(self):
        """Unwire container providers from previously wired packages and modules."""
        unwire(
            modules=self.wired_to_modules,
            packages=self.wired_to_packages,
        )

        self.wired_to_modules.clear()
        self.wired_to_packages.clear()

    def init_resources(self, resource_type=providers.Resource):
        """Initialize all container resources."""
        futures = []

        for provider in self.traverse(types=[resource_type]):
            resource = provider.init()

            if __is_future_or_coroutine(resource):
                futures.append(resource)

        if futures:
            return asyncio.gather(*futures)

    def shutdown_resources(self, resource_type=providers.Resource):
        """Shutdown all container resources."""
        def _independent_resources(resources):
            for resource in resources:
                for other_resource in resources:
                    if not other_resource.initialized:
                        continue
                    if resource in other_resource.related:
                        break
                else:
                    yield resource

        async def _async_ordered_shutdown(resources):
            while any(resource.initialized for resource in resources):
                resources_to_shutdown = list(_independent_resources(resources))
                if not resources_to_shutdown:
                    raise RuntimeError("Unable to resolve resources shutdown order")
                futures = []
                for resource in resources_to_shutdown:
                    result = resource.shutdown()
                    if __is_future_or_coroutine(result):
                        futures.append(result)
                await asyncio.gather(*futures)

        def _sync_ordered_shutdown(resources):
            while any(resource.initialized for resource in resources):
                resources_to_shutdown = list(_independent_resources(resources))
                if not resources_to_shutdown:
                    raise RuntimeError("Unable to resolve resources shutdown order")
                for resource in resources_to_shutdown:
                    resource.shutdown()

        resources = list(self.traverse(types=[resource_type]))
        if any(resource.is_async_mode_enabled() for resource in resources):
            return _async_ordered_shutdown(resources)
        else:
            return _sync_ordered_shutdown(resources)

    def load_config(self):
        """Load configuration."""
        config: providers.Configuration
        for config in self.traverse(types=[providers.Configuration]):
            config.load()

    def apply_container_providers_overridings(self):
        """Apply container providers overridings."""
        for provider in self.traverse(types=[providers.Container]):
            provider.apply_overridings()

    def reset_singletons(self):
        """Reset container singletons."""
        for provider in self.traverse(types=[providers.BaseSingleton]):
            provider.reset()
        return SingletonResetContext(self)

    def check_dependencies(self):
        """Check if container dependencies are defined.

        If any dependency is undefined, raises an error.
        """
        undefined = [
            dependency
            for dependency in self.traverse(types=[providers.Dependency])
            if not dependency.is_defined
        ]

        if not undefined:
            return

        container_name = self.parent_name if self.parent_name else self.__class__.__name__
        undefined_names = [
            f"\"{dependency.parent_name if dependency.parent_name else dependency}\""
            for dependency in undefined
        ]
        raise errors.Error(
            f"Container \"{container_name}\" has undefined dependencies: "
            f"{', '.join(undefined_names)}",
        )

    def from_schema(self, schema):
        """Build container providers from schema."""
        from .schema import build_schema
        for name, provider in build_schema(schema).items():
            self.set_provider(name, provider)

    def from_yaml_schema(self, filepath, loader=None):
        """Build container providers from YAML schema.

        You can specify type of loader as a second argument. By default, method
        uses ``SafeLoader``.
        """
        if yaml is None:
            raise errors.Error(
                "Unable to load yaml schema - PyYAML is not installed. "
                "Install PyYAML or install Dependency Injector with yaml extras: "
                "\"pip install dependency-injector[yaml]\""
            )

        if loader is None:
            loader = yaml.SafeLoader

        with open(filepath) as file:
            schema = yaml.load(file, loader)

        self.from_schema(schema)

    def from_json_schema(self, filepath):
        """Build container providers from JSON schema."""
        with open(filepath) as file:
            schema = json.load(file)
        self.from_schema(schema)

    def resolve_provider_name(self, provider):
        """Try to resolve provider name."""
        for provider_name, container_provider in self.providers.items():
            if container_provider is provider:
                return provider_name
        else:
            raise errors.Error(f"Can not resolve name for provider \"{provider}\"")

    @property
    def parent_name(self):
        """Return parent name."""
        if self.parent:
            return self.parent.parent_name

        if self.declarative_parent:
            return self.declarative_parent.__name__

        return None

    def assign_parent(self, parent):
        """Assign parent."""
        self.parent = parent


class DeclarativeContainerMetaClass(type):
    """Declarative inversion of control container meta class."""

    def __new__(type mcs, str class_name, tuple bases, dict attributes):
        """Declarative container class factory."""
        self = mcs.__fetch_self(attributes)
        if self is None:
            self = providers.Self()

        containers = {
            name: container
            for name, container in attributes.items()
            if is_container(container)
        }

        cls_providers = {
            name: provider
            for name, provider in attributes.items()
            if isinstance(provider, providers.Provider) and not isinstance(provider, providers.Self)
        }

        inherited_providers = {
            name: provider
            for base in bases
            if is_container(base) and base is not DynamicContainer
            for name, provider in base.providers.items()
        }

        all_providers = {}
        all_providers.update(inherited_providers)
        all_providers.update(cls_providers)

        wiring_config = attributes.get("wiring_config")
        if wiring_config is None:
            wiring_config = WiringConfiguration()
        if wiring_config is not None and not isinstance(wiring_config, WiringConfiguration):
            raise errors.Error(
                "Wiring configuration should be an instance of WiringConfiguration, "
                "instead got {0}".format(wiring_config)
            )

        attributes["containers"] = containers
        attributes["inherited_providers"] = inherited_providers
        attributes["cls_providers"] = cls_providers
        attributes["providers"] = all_providers
        attributes["wiring_config"] = wiring_config

        cls = <type>type.__new__(mcs, class_name, bases, attributes)

        self.set_container(cls)
        cls.__self__ = self

        for provider in cls.providers.values():
            _check_provider_type(cls, provider)

        for provider in cls.cls_providers.values():
            if isinstance(provider, providers.CHILD_PROVIDERS):
                provider.assign_parent(cls)

        return cls

    def __setattr__(cls, name, value):
        """Set class attribute.

        If value of attribute is provider, it will be added into providers
        dictionary.

        :param name: Attribute name
        :type name: object

        :param value: Attribute value
        :type value: object

        :rtype: None
        """
        if isinstance(value, providers.Provider) and name != "__self__":
            _check_provider_type(cls, value)

            if isinstance(value, providers.CHILD_PROVIDERS):
                value.assign_parent(cls)

            cls.providers[name] = value
            cls.cls_providers[name] = value
        super(DeclarativeContainerMetaClass, cls).__setattr__(name, value)

    def __delattr__(cls, name):
        """Delete class attribute.

        If value of attribute is provider, it will be deleted from providers
        dictionary.

        :param name: Attribute name
        :type name: object

        :rtype: None
        """
        if name in cls.providers and name in cls.cls_providers:
            del cls.providers[name]
            del cls.cls_providers[name]
        super(DeclarativeContainerMetaClass, cls).__delattr__(name)

    @property
    def dependencies(cls):
        """Return dependency providers dictionary.

        Dependency providers can be both of :py:class:`dependency_injector.providers.Dependency` and
        :py:class:`dependency_injector.providers.DependenciesContainer`.

        :rtype:
            dict[str, :py:class:`dependency_injector.providers.Provider`]
        """
        return {
            name: provider
            for name, provider in cls.providers.items()
            if isinstance(provider, (providers.Dependency, providers.DependenciesContainer))
        }

    def traverse(cls, types=None):
        """Return providers traversal generator."""
        yield from providers.traverse(*cls.providers.values(), types=types)

    def resolve_provider_name(cls, provider):
        """Try to resolve provider name."""
        for provider_name, container_provider in cls.providers.items():
            if container_provider is provider:
                return provider_name
        else:
            raise errors.Error(f"Can not resolve name for provider \"{provider}\"")

    @property
    def parent_name(cls):
        """Return parent name."""
        return cls.__name__

    @staticmethod
    def __fetch_self(attributes):
        self = None
        alt_names = []

        for name, value in attributes.items():
            if not isinstance(value, providers.Self):
                continue

            if self is not None and value is not self:
                raise errors.Error("Container can have only one \"Self\" provider")

            if name != "__self__":
                alt_names.append(name)

            self = value

        if self:
            self.set_alt_names(alt_names)

        return self


class DeclarativeContainer(Container, metaclass=DeclarativeContainerMetaClass):
    """Declarative inversion of control container.

    .. code-block:: python

        class Services(DeclarativeContainer):
            auth = providers.Factory(AuthService)
            users = providers.Factory(UsersService,
                                      auth_service=auth)
    """

    __IS_CONTAINER__ = True

    provider_type = providers.Provider
    """Type of providers that could be placed in container.

    :type: type
    """

    instance_type = DynamicContainer
    """Type of container that is returned on instantiating declarative
    container.

    :type: type
    """

    containers = dict()
    """Read-only dictionary of all nested containers.

    :type: dict[str, :py:class:`DeclarativeContainer`]
    """

    providers = dict()
    """Read-only dictionary of all providers.

    :type: dict[str, :py:class:`dependency_injector.providers.Provider`]
    """

    wiring_config = WiringConfiguration()
    """Wiring configuration.

    :type: WiringConfiguration
    """

    auto_load_config = True
    """Automatically load configuration when the container is created.

    :type: bool
    """

    cls_providers = dict()
    """Read-only dictionary of current container providers.

    :type: dict[str, :py:class:`dependency_injector.providers.Provider`]
    """

    inherited_providers = dict()
    """Read-only dictionary of inherited providers.

    :type: dict[str, :py:class:`dependency_injector.providers.Provider`]
    """

    overridden = tuple()
    """Tuple of overriding containers.

    :type: tuple[:py:class:`DeclarativeContainer`]
    """

    __self__ = None
    """Provider that provides current container.

    :type: :py:class:`dependency_injector.providers.Provider`
    """

    def __new__(cls, **overriding_providers):
        """Constructor.

        :return: Dynamic container with copy of all providers.
        :rtype: :py:class:`DynamicContainer`
        """
        container = cls.instance_type()
        container.provider_type = cls.provider_type
        container.wiring_config = copy_module.deepcopy(cls.wiring_config)
        container.declarative_parent = cls

        copied_providers = providers.deepcopy({ **cls.providers, **{"@@self@@": cls.__self__}})
        copied_self = copied_providers.pop("@@self@@")
        copied_self.set_container(container)

        container.__self__ = copied_self
        for name in copied_self.alt_names:
            container.set_provider(name, copied_self)

        for name, provider in copied_providers.items():
            container.set_provider(name, provider)

        if cls.auto_load_config:
            container.load_config()

        container.override_providers(**overriding_providers)
        container.apply_container_providers_overridings()

        if container.is_auto_wiring_enabled():
            container.wire()

        return container

    @classmethod
    def override(cls, object overriding):
        """Override current container by overriding container.

        :param overriding: Overriding container.
        :type overriding: :py:class:`DeclarativeContainer`

        :raise: :py:exc:`dependency_injector.errors.Error` if trying to
                override container by itself or its subclasses

        :rtype: None
        """
        if issubclass(cls, overriding):
            raise errors.Error("Container {0} could not be overridden "
                               "with itself or its subclasses".format(cls))

        cls.overridden += (overriding,)

        for name, provider in overriding.cls_providers.items():
            try:
                getattr(cls, name).override(provider)
            except AttributeError:
                pass

    @classmethod
    def reset_last_overriding(cls):
        """Reset last overriding provider for each container providers.

        :rtype: None
        """
        if not cls.overridden:
            raise errors.Error("Container {0} is not overridden".format(cls))

        cls.overridden = cls.overridden[:-1]

        for provider in cls.providers.values():
            provider.reset_last_overriding()

    @classmethod
    def reset_override(cls):
        """Reset all overridings for each container providers.

        :rtype: None
        """
        cls.overridden = tuple()

        for provider in cls.providers.values():
            provider.reset_override()


class SingletonResetContext:

    def __init__(self, container):
        self._container = container

    def __enter__(self):
        return self._container

    def __exit__(self, *_):
        self._container.reset_singletons()



class ProvidersOverridingContext:

    def __init__(self, container, overridden_providers):
        self._container = container
        self._overridden_providers = overridden_providers

    def __enter__(self):
        return self._container

    def __exit__(self, *_):
        for provider in self._overridden_providers:
            provider.reset_last_overriding()


def override(object container):
    """:py:class:`DeclarativeContainer` overriding decorator.

    :param container: Container that should be overridden by decorated
                      container.
    :type container: :py:class:`DeclarativeContainer`

    :return: Declarative container overriding decorator.
    :rtype: callable(:py:class:`DeclarativeContainer`)
    """
    def _decorator(object overriding_container):
        """Overriding decorator."""
        container.override(overriding_container)
        return overriding_container
    return _decorator


def copy(object base_container):
    """:py:class:`DeclarativeContainer` copying decorator.

    This decorator copies all providers from provided container to decorated one.
    If one of the decorated container providers matches to source container
    providers by name, it would be replaced by reference.

    :param base_container: Container that should be copied by decorated container.
    :type base_container: :py:class:`DeclarativeContainer`

    :return: Declarative container copying decorator.
    :rtype: callable(:py:class:`DeclarativeContainer`)
    """
    def _get_memo_for_matching_names(new_providers, base_providers):
        memo = {}
        for new_provider_name, new_provider in new_providers.items():
            if new_provider_name not in base_providers:
                continue
            source_provider = base_providers[new_provider_name]
            memo[id(source_provider)] = new_provider

            if hasattr(new_provider, "providers") and hasattr(source_provider, "providers"):
                sub_memo = _get_memo_for_matching_names(new_provider.providers, source_provider.providers)
                memo.update(sub_memo)
        return memo

    def _decorator(new_container):
        memo = {}
        memo.update(_get_memo_for_matching_names(new_container.cls_providers, base_container.providers))

        new_providers = {}
        new_providers.update(providers.deepcopy(base_container.providers, memo))
        new_providers.update(providers.deepcopy(new_container.cls_providers, memo))

        for name, provider in new_providers.items():
            setattr(new_container, name, provider)
        return new_container

    return _decorator


cpdef bint is_container(object instance):
    """Check if instance is container instance.

    :param instance: Instance to be checked.
    :type instance: object

    :rtype: bool
    """
    return getattr(instance, "__IS_CONTAINER__", False) is True


cpdef object _check_provider_type(object container, object provider):
    if not isinstance(provider, container.provider_type):
        raise errors.Error("{0} can contain only {1} "
                           "instances".format(container, container.provider_type))


cpdef bint _any_relative_string_imports_in(object modules):
    for module in modules:
        if not isinstance(module, str):
            continue
        if module.startswith("."):
            return True
    else:
        return False


cpdef list _resolve_string_imports(object modules, object from_package):
    return [
        importlib.import_module(module, from_package) if isinstance(module, str) else module
        for module in modules
    ]


cpdef object _resolve_calling_package_name():
    stack = inspect.stack()
    pre_last_frame = stack[0]
    module = inspect.getmodule(pre_last_frame[0])
    return module.__package__


cpdef object _resolve_package_name_from_cls(cls):
    module = importlib.import_module(cls.__module__)
    return module.__package__
