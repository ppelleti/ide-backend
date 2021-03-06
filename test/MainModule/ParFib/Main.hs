-------------------------------------------------------------------------------
-- A parallel implementation of fib in Haskell using semi-explicit
-- parallelism expressed with `par` and `pseq`

module ParFib.Main
where
import System.Time
import Control.Parallel
import System.Mem

-------------------------------------------------------------------------------
-- A purely sequential implementaiton of fib.

seqFib :: Int -> Integer
seqFib 0 = 1
seqFib 1 = 1
seqFib n = seqFib (n-1) + seqFib (n-2)

-------------------------------------------------------------------------------
-- A thresh-hold value below which the parallel implementation of fib
-- reverts to sequential implementation.

threshHold :: Int
threshHold = 25

-------------------------------------------------------------------------------
-- A parallel implementation of fib.

parFib :: Int -> Integer
parFib n
  = if n < threshHold then
      seqFib n
    else
      r `par` (l `pseq` l + r)
    where
    l  = parFib (n-1)
    r  = parFib (n-2)

-------------------------------------------------------------------------------

result :: Integer
result = parFib 24

-------------------------------------------------------------------------------

secDiff :: ClockTime -> ClockTime -> Float
secDiff (TOD secs1 psecs1) (TOD secs2 psecs2)
  = fromInteger (psecs2 - psecs1) / 1e12 + fromInteger (secs2 - secs1)

-------------------------------------------------------------------------------

main :: IO String
main
  = do t0 <- getClockTime
       pseq result (return ())
       t1 <- getClockTime
       putStrLn $ "running 'A single file with a code to run in parallel' from test/MainModule, which says fib 24 = " ++ show result
--       putStrLn ("Time: " ++ show (secDiff t0 t1))
       return $ show result

-------------------------------------------------------------------------------
