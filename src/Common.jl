# @license BSD-3 https://opensource.org/licenses/BSD-3-Clause
# Copyright (c) 2023, Institute of Automatic Control - RWTH Aachen University
# All rights reserved. 

"""
    dropsum(x; dims)
Combines sum and dropdims along dims.
"""
dropsum(x; dims) = dropdims(sum(x; dims=dims); dims=dims)

"""
    inf_to_one(x)
If x is infinity the one is returned, x otherwise
"""
inf_to_one(x) = isinf(x) ? one(x) : x
