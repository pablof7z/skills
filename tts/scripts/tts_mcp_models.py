#!/usr/bin/env python3
"""Validated input models for the TTS MCP tools."""

from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, Field, model_validator


TitleInput = Annotated[
    str,
    Field(
        min_length=1,
        description="Natural topic or topic-plus-result title; aim for 2 to 5 words, maximum 10.",
    ),
]
SummaryInput = Annotated[
    str,
    Field(
        min_length=1,
        description="One concise factual preview sentence; displayed in the player but not spoken.",
    ),
]


class AttachmentInput(BaseModel):
    label: str = Field(min_length=1, max_length=120)
    path: str = Field(min_length=1)


class SuggestionInput(BaseModel):
    title: str = Field(min_length=1, max_length=120)
    description: str | None = Field(default=None, max_length=1000)
    attachments: list[AttachmentInput] = Field(default_factory=list, max_length=10)


class QuestionInput(BaseModel):
    short_title: str = Field(min_length=1, max_length=80)
    title: str = Field(min_length=1, max_length=500)
    type: Literal["single_choice", "multiple_choice"] = "single_choice"
    description: str | None = Field(default=None, max_length=2000)
    suggestions: list[SuggestionInput] = Field(default_factory=list, max_length=20)
    attachments: list[AttachmentInput] = Field(default_factory=list, max_length=10)


class QuestionBundleInput(BaseModel):
    questions: list[QuestionInput] = Field(min_length=1, max_length=3)
    questions_preamble: str | None = Field(default=None, max_length=1000)


class ItemFilters(BaseModel):
    limit: int = Field(default=20, ge=1, le=100)
    offset: int = Field(default=0, ge=0)
    agent_name: str | None = None
    session_id: str | None = None
    archived: bool = False
    include_archived: bool = False

    @model_validator(mode="after")
    def archive_filters_are_exclusive(self) -> "ItemFilters":
        if self.archived and self.include_archived:
            raise ValueError("archived and include_archived cannot both be true")
        return self
