module Kyyn.QualifiedFixture where

import Kyyn.Edit (Edit)
import qualified Kyyn.EndpointBefore as Before
import qualified Kyyn.EndpointAfter as After

before :: Edit Before.Root ()
before = pure ()

after :: Edit After.Root ()
after = pure ()

convert :: Before.Root -> After.Root
convert Before.Root = After.Root

type Both = (Before.Root, [After.Root])
