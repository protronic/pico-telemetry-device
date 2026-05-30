"""
MicroPython-dotenv
A lightweight .env file loader for MicroPython

Import this package to load environment variables from .env files.
"""

from .micro_dotenv import (
    load_dotenv,
    get_env,
    __version__
)

__all__ = [
    'load_dotenv',
    'get_env',
    '__version__'
]
