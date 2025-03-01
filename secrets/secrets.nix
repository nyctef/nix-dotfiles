let
  user1 = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCekId/sXLRgaXZKcDzBeQyaJftBNKCXh5Hwn0KaLgbxUtCc+uJRKu9lt6eg4NegJJXc6JlJxrArd8lGXcjni4eqVzQRbRA1z01Vx1IlDJMZpoERjoWytNQ/J2MifQXlqR51kpPyU/H8kNphZ9yBAeuiZxcTySZIvijT7WELD2Raw+YMtNQKVyn93yCOuAMF9o/IdbtoesJZHcrFW+cIK3m0leNAiYpS2qZ9xo79F2CP3rn142ok5s6ts0ATtuMFR/EpeqRf9WFZIVONiewg7avi3BiJabH33djJ4RrBxXAevzevFs9UZtJqjY4XJczbWSV5nwQuPP4sh8vgkjD3PVH";
  users = [ user1 ];

  tachikoma1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILILVkTijiv2LAt8LG8l8sIPO4xzH70xZTqzEOKob4Yg";
  logikoma = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMCR88ryKVrJSqJpKI4hQoFDfPi/g/T3T/cX8o9aSLbE";
  systems = [
    tachikoma1
    logikoma
  ];

  all = systems ++ users;
in
{
  "hello.age".publicKeys = all;
  "rg-packaging-read.age".publicKeys = all;
}
