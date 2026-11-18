package com.clarigoinfotech.callio;

import java.util.Map;

/** A member of a group chat. */
public class GroupMember extends ApiObject {
  public GroupMember(Map<String, Object> data) { super(data); }

  public String username() { return str("username"); }
  public String displayName() { return str("displayName"); }
  public String userType() { return str("userType"); }
  public String sipUser() { return str("sipUser"); }
}
