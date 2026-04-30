"""Retrieval helpers for the Small-Area Global Elections (SAGE) archive."""
from .core import (
    sage_load,
    sage_polygons,
    sage_preference_votes,
    sage_countries,
    sage_years,
    sage_columns,
    set_source,
    get_source,
)

__all__ = [
    "sage_load",
    "sage_polygons",
    "sage_preference_votes",
    "sage_countries",
    "sage_years",
    "sage_columns",
    "set_source",
    "get_source",
]
__version__ = "0.1.0"
