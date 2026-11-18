package com.clarigoinfotech.callio;

import java.util.List;

import java.util.Map;

/** A group chat. */
public class Group extends ApiObject {
  public Group(Map<String, Object> data) { super(data); }

  public String id() { return str("id"); }
  public String name() { return str("name"); }
  public String createdAt() { return str("createdAt"); }
  public List<GroupMember> members() { return list("members", GroupMember::new); }
}
