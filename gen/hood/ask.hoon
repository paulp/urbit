::
::::  /hoon/ask/hood/gen
  ::
/?    310
:-  %say
|=  {^ {mel/cord $~} $~}
=+  adr=(star ;~(less (mask "\"\\()[],:;<>@") prn))
=+  dom=[;~(plug dlab dot (most dot dlab))]:urlp
=+  ~|(bad-email+mel (rash mel ;~((glue pat) adr dom)))
helm-send-ask+mel
